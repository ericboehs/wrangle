# frozen_string_literal: true

require "securerandom"

require_relative "errors"
require_relative "jxa_bridge"
require_relative "observation"

module Wrangle
  # One scoped Safari window, observed with snapshot.js and mutated only through guarded DOM actions.
  #
  # Scope is the whole safety boundary: one window id, one tab position, one expected URL, and one
  # document epoch. Losing any of them ends the session rather than starting a search for a
  # replacement, because the window this session was given is the only window it was given.
  class Safari
    MAX_TEXT = 2000
    SETTLE_SECONDS = 5
    ACTION_KINDS = %w[click fill select scroll wait].freeze
    STATE_KEYS = %w[url title text actions scroll marker page_key guards].freeze
    # Binding a new document and mutating one are verified against Safari; reads rely on the epoch.
    VERIFIED_OPS = %w[install act].freeze

    attr_reader :window_id, :tab_index, :mode, :epoch, :expected_url, :bounds

    class << self
      # Open a window this session owns. It is the only kind of window Wrangle will ever close.
      def open(url, display: nil, bounds: nil, restore_focus: true, **, &block)
        session = new(url: url, display: display, bounds: bounds, restore_focus: restore_focus, **)
        block ? use(session, &block) : session
      end

      # Take over a window that is already open, already signed in, and already where it was left.
      def attach(window_id:, url: nil, display: nil, bounds: nil, **, &block)
        session = new(window_id: window_id, url: url, display: display, bounds: bounds, **)
        block ? use(session, &block) : session
      end

      # Report Safari windows. Titles and URLs identify a tab to its owner, so they are opt-in.
      def windows(titles: false, bridge: nil)
        with_bridge(bridge) { |active| active.request("windows", titles: titles || nil).fetch("windows") }
      end

      # Report attached displays in AppleScript window coordinates.
      def displays(bridge: nil)
        with_bridge(bridge) { |active| active.request("displays").fetch("displays") }
      end

      private

      def use(session)
        yield session
      ensure
        session.close
      end

      def with_bridge(bridge)
        return yield bridge if bridge

        active = JxaBridge.new
        active.start
        begin
          yield active
        ensure
          active.close
        end
      end
    end

    def initialize(url: nil, window_id: nil, display: nil, bounds: nil, bridge: nil,
                   load_timeout: 15, restore_focus: true, allow_multiple_safari: false)
      @attaching = !window_id.nil?
      validate!(url, window_id, display, bounds)

      @bridge = bridge || JxaBridge.new
      @mode = @attaching ? "attach" : "dedicated"
      @owned = !@attaching
      @closed = false
      @poisoned = nil
      @expect_navigation = false

      begin
        guard_single_safari(@bridge.start, allow_multiple_safari)
        info = if @attaching
                 attach_window(window_id, url, display, bounds)
               else
                 open_window(url, display, bounds,
                             restore_focus, load_timeout)
               end
        @window_id = integer(info["window_id"], "window_id")
        @tab_index = integer(info["tab_index"], "tab_index")
        @expected_url = info["url"] if info["url"].is_a?(String)
        @bounds = info["bounds"]
        install
      rescue StandardError
        shutdown(suppress: true)
        raise
      end
    end

    def owned? = @owned

    # Return one snapshot.js observation of the scoped tab.
    def observe
      ensure_open
      deadline = now + SETTLE_SECONDS
      result = nil
      loop do
        result = page_request({ "op" => "observe" })
        if result["status"] == "epoch_lost"
          # Our own window may navigate and be rebound. A handed-over tab may not: if the user went
          # somewhere else, the session is over.
          unless @mode == "dedicated" || @expect_navigation
            poison(ScopeLost.new("The handed-over Safari tab replaced its document"))
          end
          result = install
        end
        break if result["status"] == "ok"
        raise StalePage, "The scoped Safari page did not settle" if now > deadline

        sleep 0.05
      end

      state = result["state"]
      unless state.is_a?(Hash) && STATE_KEYS.all? { |key| state.key?(key) }
        raise BridgeError, "The scoped Safari page returned an incomplete observation"
      end

      state["fingerprint"] = Observation.fingerprint(state)
      @expected_url = state["url"]
      @expect_navigation = false
      state
    end

    # Compare an observed decision with current page state, without mutating anything.
    def fresh?(page, action = nil)
      ensure_open
      if action.is_a?(Hash) && %w[click select].include?(action["kind"])
        node = action["node"]
        return false unless node.is_a?(Integer)

        result = page_request({ "op" => "guard", "node" => node })
        return false unless result["status"] == "ok"

        return result["guard"] == [page["page_key"], page["guards"][node.to_s]]
      end

      result = page_request({ "op" => "marker" })
      result["status"] == "ok" && result["marker"] == page["marker"]
    end

    # Execute exactly one observed action in the scoped tab.
    def act(action, page, text: nil)
      ensure_open
      observed = Observation.require_observed(action, page)
      kind = observed["kind"]
      validate_action!(observed, kind, text)

      raise StalePage, "Page changed since this decision. Observe again." unless fresh?(page, observed)

      if kind == "wait"
        sleep 0.1
        return { "executed" => observed["id"] }
      end

      nonce = SecureRandom.hex(8)
      request = { "op" => "act", "action" => observed, "nonce" => nonce }
      request["text"] = text if kind == "fill"

      result = begin
        page_request(request)
      rescue ScopeLost, DeliveryUnknown
        raise
      rescue BridgeError => e
        resolve_delivery(nonce, e)
      end

      case result["status"]
      when "executed"
        # A click can navigate. Let exactly the next observation re-pin the document.
        @expect_navigation = kind != "scroll"
        { "executed" => observed["id"] }
      when "blocked"
        raise StalePage, "Target changed or is covered. Observe again."
      when "epoch_lost"
        # The epoch is checked before anything is dispatched, so nothing was mutated.
        raise StalePage, "The document changed before execution. Observe again."
      else
        poison(DeliveryUnknown.new("Safari reported #{result["status"].inspect} for a dispatched action"))
      end
    end

    # Close only a window this session opened. An attached window is always left alone.
    def close
      return if @closed

      shutdown(suppress: false)
    end

    private

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def validate!(url, window_id, display, bounds)
      if @attaching && !window_id.is_a?(Integer)
        raise ArgumentError, "window_id must be the integer id of an existing Safari window"
      end
      if !@attaching && !(url.is_a?(String) && !url.strip.empty?)
        raise ArgumentError, "Supply a URL for a dedicated Safari window"
      end
      raise ArgumentError, "Choose either a display or explicit bounds" if display && bounds
      if display && !(display.is_a?(Integer) && !display.negative?)
        raise ArgumentError, "display must be a non-negative index"
      end
      return unless bounds && !(bounds.size == 4 && bounds.all?(Integer))

      raise ArgumentError, "bounds must be four integers: x, y, width, height"
    end

    def validate_action!(observed, kind, text)
      raise ArgumentError, "Unsupported Safari action" unless ACTION_KINDS.include?(kind)

      validate_text!(kind, text)
      validate_target!(observed, kind)
    end

    def validate_text!(kind, text)
      if kind == "fill"
        unless text.is_a?(String) && !text.empty? && text.length <= MAX_TEXT
          raise ArgumentError, "Safari text input requires a non-empty string of at most #{MAX_TEXT} characters"
        end
      elsif !text.nil?
        raise ArgumentError, "Text is valid only for a Safari fill action"
      end
    end

    def validate_target!(observed, kind)
      raise ArgumentError, "Safari select requires an observed option value" if kind == "select" &&
                                                                                !observed["value"].is_a?(String)
      if kind == "scroll" && !(observed["delta"].is_a?(Integer) && !observed["delta"].zero?)
        raise ArgumentError, "Safari scroll requires a non-zero integer delta"
      end
      return unless %w[click fill select].include?(kind) && !observed["node"].is_a?(Integer)

      raise ArgumentError, "Safari actions require an observed node"
    end

    # safaridriver leaves extra Safari processes behind, and window ids are only unique within one.
    def guard_single_safari(ping, allowed)
      instances = ping.is_a?(Hash) ? ping["safari_instances"] : nil
      return unless instances.is_a?(Integer) && instances > 1 && !allowed

      raise Error, "#{instances} Safari processes are running, so window ids are ambiguous. " \
                   "Quit the extra instances or pass allow_multiple_safari: true."
    end

    def open_window(url, display, bounds, restore_focus, load_timeout)
      @bridge.request("open", url: url, display: display, bounds: bounds,
                              restore_focus: restore_focus, timeout: load_timeout)
    end

    def attach_window(window_id, url, display, bounds)
      info = @bridge.request("attach", window_id: window_id, url: url)
      @bridge.request("bounds", window_id: info["window_id"], display: display, bounds: bounds) if display || bounds
      info
    end

    def install
      epoch = SecureRandom.hex(8)
      result = page_request({ "op" => "install" }, epoch: epoch)
      @epoch = epoch if result["status"] == "ok"
      result
    end

    def scope
      built = { "window_id" => @window_id, "mode" => @mode, "tab_index" => @tab_index }
      built["url"] = @expected_url if @mode == "attach" && !@expect_navigation && @expected_url
      built
    end

    def page_request(request, epoch: nil)
      # Binding a document or changing one is worth the extra Apple Events; a read is guarded by the epoch.
      @bridge.evaluate(scope, request.merge("epoch" => epoch || @epoch),
                       verify: VERIFIED_OPS.include?(request["op"]))
    rescue BridgeCallError => e
      poison(ScopeLost.new(e.message)) if e.scope?
      raise
    end

    # A dispatched action with no reply is resolved by reading its nonce, never by repeating it.
    def resolve_delivery(nonce, error)
      poison(DeliveryUnknown.new("The bridge died while an action was in flight"), cause: error) unless @bridge.running?

      probe = begin
        page_request({ "op" => "probe" })
      rescue Error => e
        poison(DeliveryUnknown.new("The action's outcome could not be read back"), cause: e)
      end

      unless probe["status"] == "ok"
        poison(DeliveryUnknown.new("The document changed while an action was in flight"), cause: error)
      end

      record = probe["act"]
      raise Error, "Safari never executed the action" unless record.is_a?(Hash) && record["nonce"] == nonce
      return { "status" => "executed" } if record["phase"] == "finished"

      poison(DeliveryUnknown.new("An action started without confirming completion"), cause: error)
    end

    def poison(error, cause: nil)
      @poisoned ||= error
      raise error, cause: cause
    end

    def ensure_open
      raise Error, "This Wrangle session is closed" if @closed
      raise @poisoned if @poisoned
    end

    def shutdown(suppress:)
      return if @closed

      @closed = true
      error = nil
      # A session that may have mutated the page cannot describe what it would be closing.
      if @owned && @window_id && !@poisoned.is_a?(DeliveryUnknown)
        begin
          @bridge.request("close", window_id: @window_id, owned: true)
        rescue BridgeCallError => e
          # The window is gone or no longer exclusively ours. Leaving it open is the right outcome.
          error = e unless e.scope?
        rescue StandardError => e
          error = e
        end
      end
      @bridge.close
      raise error if error && !suppress
    end

    def integer(value, name)
      raise BridgeError, "The bridge returned no #{name}" unless value.is_a?(Integer)

      value
    end
  end
end
