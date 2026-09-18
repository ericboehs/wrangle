# frozen_string_literal: true

require "fileutils"
require "json"
require "socket"

require_relative "safari"

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
    SETTLE_POLL = 0.3
    STABLE_ROUNDS = 2

    def self.socket_path(name)
      File.join(ENV["WRANGLE_HOME"] || File.join(Dir.home, ".wrangle"), "#{name}.sock")
    end

    def self.run(socket_path, options)
      new(socket_path, options).run
    end

    # `session` is injectable so the protocol, the diffing, and the refusal shapes can be tested
    # against a fake bridge instead of a browser.
    def initialize(socket_path, options, session: nil)
      @socket_path = socket_path
      @options = options
      @session = session
      @page = nil
      @acted = 0
    end

    def run
      FileUtils.mkdir_p(File.dirname(@socket_path))
      FileUtils.rm_f(@socket_path)
      @session ||= start_session
      serve(UNIXServer.new(@socket_path))
    ensure
      shutdown
    end

    private

    def start_session
      if @options["window_id"]
        Safari.attach(window_id: @options["window_id"], display: @options["display"])
      else
        Safari.open(@options.fetch("url"), display: @options["display"], bounds: @options["bounds"])
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
    end

    def handle(request)
      case request["op"]
      when "status" then status
      when "observe" then observe(request["settle"].to_f)
      when "act" then act(request)
      when "text" then { "text" => current["text"] }
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
        "pid" => Process.pid, "window_id" => @session.window_id, "mode" => @session.mode,
        "owned" => @session.owned?, "url" => @session.expected_url, "actions_taken" => @acted,
        "observed" => !@page.nil?
      }
    end

    def current
      @page || (@page = @session.observe)
    end

    def observe(settle)
      before = @page
      @page = settle.positive? ? settled(settle) : @session.observe
      describe(before, @page)
    end

    # Poll until the page stops changing, rather than sleeping a guessed number of seconds.
    def settled(timeout)
      page = @session.observe
      deadline = now + timeout
      stable = 0
      while now < deadline && stable < STABLE_ROUNDS
        sleep SETTLE_POLL
        nxt = @session.observe
        stable = nxt["fingerprint"] == page["fingerprint"] ? stable + 1 : 0
        page = nxt
      end
      page
    end

    def act(request)
      raise ArgumentError, "Observe before acting" unless @page

      action = chosen(request["ref"])
      before = @page
      @session.act(action, @page, text: request["text"])
      @acted += 1
      @page = settled(request.fetch("settle", 3).to_f)
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

    def presence(value) = value.nil? || value.to_s.empty? ? nil : value.to_s

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def shutdown
      begin
        @session&.close
      rescue Wrangle::Error
        nil # A poisoned session refuses to close its window. That refusal is the correct outcome.
      end
      FileUtils.rm_f(@socket_path) if @socket_path
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
    rescue Errno::ENOENT, Errno::ECONNREFUSED
      raise BridgeError, "No wrangle session at #{@socket_path}. Start one with `wrangle open <url>`."
    ensure
      socket&.close
    end
  end
end
