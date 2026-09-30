# frozen_string_literal: true

require "fileutils"
require "json"
require "socket"

require_relative "run_loop"
require_relative "safari"
require_relative "timing"

module Wrangle
  # A Safari session that outlives a single command.
  #
  # An agent working through a shell gets one process per command, but a browser session is only
  # useful if it persists between them. This holds one `Wrangle::Safari` open behind a Unix socket so
  # `observe`, `act`, and `act` again are three commands against the same window.
  #
  # Everything it returns is shaped for a reader who has to decide what to do next: what changed, what
  # is now available, and — when something failed — whether the failure is worth retrying.
  class SessionServer
    # Polling for a page to stop moving, which is the server's own business: the run loop asks it to
    # settle and says for how long, but never how.
    STEADY_POLL = 0.05
    SETTLE_POLL = 0.3
    STABLE_ROUNDS = 2
    # A click that navigates changes nothing for the first few hundred milliseconds. Without a floor,
    # two identical reads arrive before the browser has begun and the page is declared settled, which
    # reports a working action as "nothing changed" — worse than saying nothing at all.
    QUIET_FLOOR = 1.5

    def self.socket_path(name)
      File.join(ENV["WRANGLE_HOME"] || File.join(Dir.home, ".wrangle"), "#{name}.sock")
    end

    def self.run(socket_path, options)
      new(socket_path, options).run
    end

    # `session` is injectable so the protocol, the diffing, and the refusal shapes can be tested
    # against a fake bridge instead of a browser.
    def initialize(socket_path, options, session: nil, jev: nil, timing: Timing)
      @socket_path = socket_path
      @options = options
      @session = session
      @jev = jev
      @timing = timing
      @page = nil
      @acted = 0
      @history = []
    end

    def run
      FileUtils.mkdir_p(File.dirname(@socket_path))
      FileUtils.rm_f(@socket_path)
      @session ||= start_session
      serve(UNIXServer.new(@socket_path))
    ensure
      shutdown
    end

    # What the run loop is allowed to ask for. It decides what should happen; everything that reads
    # or changes the page lives here, so there is one file to read when asking what Wrangle can do to
    # a window.
    attr_reader :page

    # Proposes, and does nothing else. Acting on the proposal is a separate, explicit request.
    def decide(request)
      page = current
      chooser = decider(request)
      started = now
      questions = chooser.questions(page)
      answer = asked(request, chooser.state(page, @history), questions)
      choice = chooser.resolve(answer, page)

      { "operation" => choice.operation, "action" => choice.label, "kind" => choice.action&.fetch("kind"),
        "confidence" => choice.confidence, "target_confidence" => choice.target_confidence,
        "decided_in_ms" => ((now - started) * 1000).round, "executed" => false,
        "model" => answer["model"], "input_tokens" => answer.dig("usage", "input_tokens"),
        "choice" => choice }
    end

    # Asks Jev, and watches the page while it thinks.
    #
    # Proving a page has stopped moving takes two looks a couple of hundred milliseconds apart, and
    # Jev takes about 380ms to answer. Those used to be paid one after the other, which is why the
    # settle was worth skipping and why it was in fact skipped for months. Run together the looks are
    # free: they fit inside a wait the step was making anyway.
    #
    # None of this changes what the decision is about. The answer belongs to `page`, the snapshot it
    # was asked about, and the guard at act time still has the last word on whether it may be used.
    # What the watching buys is a fresh observation sitting ready the moment the answer lands, so a
    # decision the page outran costs one more request instead of a read on top of it.
    def asked(request, state, questions)
      @watched = nil
      thinking = Thread.new { jev(request).ask(state: state, questions: questions) }
      thinking.report_on_exception = false
      watch(thinking)
      thinking.value
    ensure
      thinking&.kill
    end

    # Stops at the first pair of reads that agree: once the page has held still there is nothing
    # further to learn, and Apple Events are not free even when nobody is waiting on them.
    def watch(thinking)
      seen = @page && @page["fingerprint"]
      while thinking.alive?
        pause(STEADY_POLL)
        break unless thinking.alive?

        looked = @session.observe
        # Stamped with the number of actions taken. A read is only ever worth promoting while that
        # number still holds: after a mutation it describes a page that no longer exists, and the one
        # way this could report the wrong thing is by outliving the page it was taken from.
        @watched = [@acted, looked]
        break if looked["fingerprint"] == seen

        seen = looked["fingerprint"]
      end
    rescue Error
      # A read that fails while the answer is still coming is not this step's problem to solve. The
      # guard, or the next read, will run into whatever is wrong and report it in its own terms.
      @watched = nil
    end

    # The run loop decides; this stays the only thing that touches the page, so there is one place to
    # read when asking what Wrangle is allowed to do to a window.
    def perform(choice, text)
      before = @page
      began = now
      @session.act(choice.action, @page, text: text)
      acted = now
      @acted += 1
      @page = @session.observe
      changed = before["fingerprint"] != @page["fingerprint"]
      @history << { "action" => choice.label, "kind" => choice.action["kind"], "text" => text,
                    "page_changed" => changed }
      { "executed" => true, "text" => text, "page_changed" => changed,
        "act_ms" => ((acted - began) * 1000).round, "read_ms" => ((now - acted) * 1000).round }
    end

    # Promotes the read taken while Jev was thinking, if nothing has been acted on since. A rejected
    # decision touches nothing, so that read is the same page a fresh one would return, a poll
    # sooner. A read from before an action is not, and is dropped rather than reused.
    def observe!
      acted, looked = @watched
      @watched = nil
      @page = (looked if looked && acted == @acted) || @session.observe
    end

    # A decision about a page that is still rendering is a decision thrown away: Jev answers in
    # ~350ms, and the freshness check then rejects it. Autocomplete menus and calendars settle in far
    # less than that, so a couple of cheap observations cost much less than the wasted call they avoid.
    # This is a budget, not a floor — a page that is already still returns immediately after one poll.
    def steady(budget)
      return @page unless budget.positive?

      deadline = now + budget
      loop do
        before = @page["fingerprint"]
        pause(STEADY_POLL)
        @page = @session.observe
        return @page if @page["fingerprint"] == before || now >= deadline
      end
    end

    # Three actions in a row that changed nothing is not progress, whatever the model believes — and
    # neither is clicking the same control three times while the page shuffles underneath. Both are
    # the same failure: the run is circling, and a human or the calling model should look at it.
    def stalled?
      recent = @history.last(3)
      return false unless recent.length == 3

      recent.none? { |entry| entry["page_changed"] || entry["kind"] == "wait" } ||
        (recent.map { |entry| entry["action"] }.uniq.one? && recent.none? { |e| e["kind"] == "wait" })
    end

    private

    def mcp? = @options["backend"].to_s == "mcp"

    def start_session
      if @options["window_id"]
        raise ArgumentError, "The MCP backend cannot attach to an existing window" if mcp?

        Safari.attach(window_id: @options["window_id"], display: @options["display"], timing: @timing)
      else
        Safari.open(@options.fetch("url"),
                    display: @options["display"], bounds: @options["bounds"], timing: @timing,
                    **(mcp? ? { bridge: McpBridge.new } : {}))
      end
    end

    def serve(server)
      File.chmod(0o600, @socket_path)
      loop do
        client = server.accept
        line = client.gets
        next client.close unless line

        request = parse(line)
        client.puts(JSON.generate(dispatch(request)))
        client.close
        break if request["op"] == "close"
      end
    end

    def parse(line)
      JSON.parse(line)
    rescue JSON::ParserError
      { "op" => "bad" }
    end

    def dispatch(request)
      { "ok" => true, "value" => handle(request) }
    rescue Wrangle::Error => e
      refusal(e.class.name.split("::").last, e.message, terminal: e.is_a?(ScopeLost) || e.is_a?(DeliveryUnknown))
    rescue ArgumentError => e
      refusal("ArgumentError", e.message, terminal: false)
    rescue StandardError => e
      # A bug is still a reply. The client is blocked on a socket read, so a server that dies here
      # hangs the caller forever instead of telling it anything — the session is suspect afterwards,
      # so this is terminal, but it is reported rather than silently fatal.
      refusal(e.class.name, "internal error: #{e.message} (#{e.backtrace&.first})", terminal: true)
    end

    def handle(request)
      case request["op"]
      when "status" then status
      when "observe" then observe(request["settle"].to_f)
      when "act" then act(request)
      when "text" then { "text" => fresh_text(request) }
      when "decide" then decide(request)
      when "run" then run_goal(request)
      when "close" then { "closing" => true }
      else raise ArgumentError, "Unknown op #{request["op"].inspect}"
      end
    end

    # A refusal says what to do about itself. `retryable` is the difference between "look again" and
    # "this session is over", which is the single most useful bit for whoever is deciding next.
    def refusal(name, message, terminal:)
      {
        "ok" => false, "class" => name, "error" => message, "terminal" => terminal,
        "retryable" => !terminal,
        "hint" => if terminal
                    "This session cannot continue. Start a new one."
                  else
                    "Run `wrangle observe` and choose an action from the fresh list."
                  end
      }
    end

    def status
      {
        "pid" => Process.pid, "backend" => @options["backend"] || "jxa",
        "window_id" => @session.window_id, "mode" => @session.mode,
        "owned" => @session.owned?, "url" => @session.expected_url, "actions_taken" => @acted,
        "observed" => !@page.nil?
      }
    end

    def current
      @page || (@page = @session.observe)
    end

    # Reading text off a cached observation silently reports the page as it was before the last
    # navigation finished. Text is always read fresh.
    def fresh_text(request)
      settle = request["settle"].to_f
      @page = settle.positive? ? settled(settle, @page) : @session.observe
      @page["text"]
    end

    def observe(settle)
      before = @page
      @page = settle.positive? ? settled(settle, before) : @session.observe
      describe(before, @page)
    end

    # Poll until the page stops changing, rather than sleeping a guessed number of seconds. Stability
    # only counts once the page has moved, or once the floor has passed with it sitting still.
    # When the caller has told us what they are waiting for, wait for exactly that and stop. Waiting
    # for a page to go quiet is a proxy; waiting for the text you need is the real thing, and a busy
    # page like a results list may never go quiet at all.
    def settled(timeout, baseline, expect = nil)
      page = @session.observe
      return page if arrived?(page, expect)

      deadline = now + timeout
      floor = now + [QUIET_FLOOR, timeout].min
      stable = 0
      moved = departed?(baseline, page)
      until now >= deadline || (stable >= STABLE_ROUNDS && (moved || now >= floor))
        pause(SETTLE_POLL)
        nxt = @session.observe
        stable = nxt["fingerprint"] == page["fingerprint"] ? stable + 1 : 0
        moved ||= departed?(baseline, nxt)
        page = nxt
        break if arrived?(page, expect)
      end
      page
    end

    def arrived?(page, expect)
      !expect.nil? && page["text"].match?(expect)
    end

    def departed?(baseline, page)
      !baseline.nil? && baseline["fingerprint"] != page["fingerprint"]
    end

    def act(request)
      raise ArgumentError, "Observe before acting" unless @page

      action = chosen(request["ref"])
      before = @page
      @session.act(action, @page, text: request["text"])
      @acted += 1
      @page = settled(request.fetch("settle", 3).to_f, before, request["expect"])
      describe(before, @page).merge("executed" => label(action), "kind" => action["kind"])
    end

    def chosen(ref)
      available = @page["actions"]
      unless ref.is_a?(Integer) && ref.positive? && ref <= available.size
        raise ArgumentError, "No action ##{ref.inspect} in the last observation; it offered #{available.size}"
      end

      available[ref - 1]
    end

    def describe(before, after)
      {
        "url" => after["url"], "title" => after["title"],
        "fingerprint" => after["fingerprint"][0, 12],
        "scroll" => after["scroll"], "text_chars" => after["text"].length,
        "actions" => after["actions"].each_with_index.map { |action, index| compact(action, index) },
        "changed" => change(before, after)
      }
    end

    def compact(action, index)
      {
        "ref" => index + 1, "kind" => action["kind"], "role" => action["role"],
        "label" => label(action), "value" => presence(action["value"])
      }.compact
    end

    # The whole point of the interactive mode: after an action, say what actually moved. An agent that
    # can see "nothing changed" can course-correct; one that only gets a page dump has to guess.
    def change(before, after)
      return nil unless before

      old = before["actions"].map { |action| label(action) }
      new = after["actions"].map { |action| label(action) }
      {
        "same_page" => before["fingerprint"] == after["fingerprint"],
        "url_changed" => before["url"] != after["url"],
        "text_delta" => after["text"].length - before["text"].length,
        "scroll_delta" => after["scroll"]["y"] - before["scroll"]["y"],
        "appeared" => (new - old).uniq.first(20),
        "disappeared" => (old - new).uniq.first(20)
      }
    end

    def label(action) = action["label"].to_s

    # --- deciding ----------------------------------------------------------------------------

    def decider(request)
      Decider.new(goal: request.fetch("goal"))
    end

    def jev(request)
      @jev ||= Jev.from_env(endpoint: request["endpoint"], model: request["model"])
    end

    # No fixed pause anywhere. Waiting is an operation the model can choose when a control is missing
    # or results are still loading, so a page that updates instantly costs nothing.
    def run_goal(request)
      raise ArgumentError, "run needs execute: true to touch the page" unless request["execute"]

      expect = request["expect"] && Regexp.new(request["expect"], Regexp::IGNORECASE)
      plan = Array(request["plan"]).filter_map { |goal| presence(goal) }
      plan = [request["goal"]] if plan.empty?
      summarise(request, RunLoop.new(self, request, expect, timing: @timing).run(plan), expect)
    end

    def summarise(request, steps, expect)
      if steps.last&.fetch("operation", nil) == "RESTALE"
        steps << { "operation" => "HANDOFF", "confidence" => 0.0,
                   "action" => "The page kept moving faster than a decision could be made; look at " \
                               "it yourself and act by ref" }
      end
      proven = expect ? fresh_text(request).match?(expect) : nil
      { "goal" => request["goal"], "legs" => Array(request["plan"]).length,
        "steps" => steps, "stopped" => steps.last&.fetch("operation", nil),
        "expected" => expect&.source, "proven" => proven }
    end

    def presence(value) = value.nil? || value.to_s.empty? ? nil : value.to_s

    def now = @timing.now
    def pause(seconds) = @timing.sleep(seconds)

    def shutdown
      begin
        @session&.close
      rescue Wrangle::Error
        nil # A poisoned session refuses to close its window. That refusal is the correct outcome.
      end
      return unless @socket_path

      FileUtils.rm_f(@socket_path)
      FileUtils.rm_f("#{@socket_path}.pid")
    end
  end

  # Talks to a SessionServer over its socket. One request, one reply, one connection.
  class SessionClient
    def initialize(socket_path)
      @socket_path = socket_path
    end

    def running?
      File.socket?(@socket_path) && begin
        call("status")
        true
      rescue Wrangle::Error
        false
      end
    end

    def call(op, **params)
      socket = UNIXSocket.new(@socket_path)
      socket.puts(JSON.generate(params.merge(op: op)))
      reply = socket.gets
      raise BridgeError, "The wrangle session closed without replying" unless reply

      JSON.parse(reply)
    rescue Errno::EPIPE, Errno::ECONNRESET, Errno::ENOTCONN
      # The session was there when the connection opened and gone before it answered. Same outcome as
      # a reply that never came, and a caller should not have to know the difference at errno level —
      # macOS reports this as any of three errnos depending on how far the write got.
      raise BridgeError, "The wrangle session closed without replying"
    rescue Errno::ENOENT, Errno::ECONNREFUSED
      raise BridgeError, "No wrangle session at #{@socket_path}. Start one with `wrangle open <url>`."
    ensure
      socket&.close
    end
  end
end
