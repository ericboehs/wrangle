# frozen_string_literal: true

require "json"
require "monitor"
require "open3"

require_relative "errors"

module Wrangle
  # A persistent `osascript -l JavaScript` process speaking newline-delimited JSON.
  #
  # Spawning osascript costs about 56 ms; a request to a process that is already running costs about
  # 0.3 ms. Keeping one alive means the only cost left is the Apple Event itself, which is roughly
  # 17 ms and does not care how much data it carries.
  class JxaBridge
    OSASCRIPT = ["/usr/bin/osascript", "-l", "JavaScript"].freeze
    SCRIPTS = File.expand_path("js", __dir__)
    MAX_LINE_BYTES = 4_000_000
    STDERR_LINES = 50

    EOF = :eof
    INVALID = :invalid
    OVERSIZED = :oversized

    attr_reader :pid

    def initialize(command: OSASCRIPT, script: File.join(SCRIPTS, "bridge.js"),
                   request_timeout: 30, startup_timeout: 20)
      raise ArgumentError, "Bridge timeouts must be positive" unless [request_timeout, startup_timeout].min.positive?

      @command = command
      @script = script
      @request_timeout = request_timeout
      @startup_timeout = startup_timeout
      @lock = Monitor.new # Monitor, not Mutex: start re-enters request.
      @lines = Thread::Queue.new
      @stderr = []
      @next_id = 1
      @started = false
      @closed = false
    end

    def running? = @wait&.alive? || false

    def stderr = @stderr.dup

    # Spawn the bridge, confirm it answers, and hand it the page scripts once.
    #
    # The scripts are sent at startup rather than per call. That keeps about 12 KB off every
    # subsequent request and, more importantly, means the wire carries data and never program text.
    def start
      @lock.synchronize do
        raise BridgeError, "Bridge is already started" if @started
        raise BridgeError, "Bridge script is missing: #{@script}" unless File.file?(@script)

        @started = true
        spawn_process
        ping = request("ping", timeout: @startup_timeout)
        request("scripts", timeout: @startup_timeout,
                           page: File.read(File.join(SCRIPTS, "page.js")),
                           snapshot: File.read(File.join(SCRIPTS, "snapshot.js")))
        ping
      end
    end

    # Send one operation and return its validated value.
    def request(op, timeout: nil, **params)
      @lock.synchronize do
        ensure_running
        id = @next_id
        @next_id += 1
        begin
          @stdin.write("#{JSON.generate(params.compact.merge(id: id, op: op))}\n")
        rescue Errno::EPIPE, IOError
          raise BridgeError, "The bridge is no longer accepting requests"
        end
        response = receive(id, timeout || @request_timeout)
        raise BridgeCallError.new(response["code"], response["error"]) unless response["ok"]

        response.fetch("value")
      end
    end

    # Run one code-owned page request inside the scoped tab and decode its JSON reply.
    #
    # The request is encoded here and passed into a fixed page function as a single JSON argument.
    # It is never interpolated into the program's structure.
    def evaluate(scope, page_request, verify: false, timeout: nil)
      raise ArgumentError, "Bridge evaluation needs a scope and a request" unless scope.is_a?(Hash) &&
                                                                                  page_request.is_a?(Hash)

      value = request("eval", scope: scope, payload: payload(page_request), verify: verify, timeout: timeout)
      result = value["result"]
      raise BridgeError, "Bridge evaluation returned no page result" unless result.is_a?(String)

      decoded = begin
        JSON.parse(result)
      rescue JSON::ParserError
        raise BridgeError, "The page returned invalid JSON"
      end
      raise BridgeError, "The page returned an invalid result" unless decoded.is_a?(Hash) &&
                                                                      decoded["status"].is_a?(String)

      decoded
    end

    # Encode a code-owned page request. Model output only ever travels as a JSON value.
    def payload(page_request)
      op = page_request["op"] || page_request[:op]
      raise ArgumentError, "A page request needs an operation" unless op.is_a?(String)

      JSON.generate(page_request)
    end

    # Ask the bridge to exit, then make sure the process is gone.
    def close
      @lock.synchronize do
        return if @closed
        return @closed = true unless @started

        begin
          # Marked closed only after the request: a bridge must be allowed to answer its own exit.
          request("exit", timeout: 2) if running?
        rescue Error
          nil # A bridge that will not be asked to leave is made to.
        end
        @closed = true
        @stdin&.close unless @stdin&.closed?
        return if @wait.join(2)

        Process.kill("TERM", @wait.pid)
        @wait.join(2) || Process.kill("KILL", @wait.pid)
      end
    end

    private

    def spawn_process
      @stdin, stdout, stderr, @wait = Open3.popen3(*@command, @script)
      @pid = @wait.pid
      @stdin.sync = true
      [@stdin, stdout, stderr].each { |io| io.set_encoding("UTF-8") }
      @readers = [
        Thread.new do
          stdout.each_line do |line|
            @lines << if line.bytesize > MAX_LINE_BYTES
                        OVERSIZED
                      else
                        begin
                          JSON.parse(line)
                        rescue JSON::ParserError
                          INVALID
                        end
                      end
          end
          @lines << EOF
        end,
        Thread.new do
          stderr.each_line { |line| @stderr.shift if @stderr.push(line.chomp).size > STDERR_LINES }
        end
      ]
      @readers.each { |thread| thread.abort_on_exception = false }
    rescue SystemCallError => e
      raise BridgeError, "Could not start osascript: #{e.message}"
    end

    def receive(id, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise BridgeTimeout, "Bridge request #{id} timed out" if remaining <= 0

        message = @lines.pop(timeout: remaining)
        raise BridgeTimeout, "Bridge request #{id} timed out" if message.nil?
        raise BridgeError, "The bridge exited#{" (#{@stderr.last})" if @stderr.any?}" if message == EOF
        raise BridgeError, "The bridge returned an oversized line" if message == OVERSIZED
        raise BridgeError, "The bridge wrote invalid JSON" if message == INVALID
        raise BridgeError, "The bridge returned a non-object response" unless message.is_a?(Hash)
        # A late reply to an abandoned request is discarded rather than mistaken for this one.
        next if message["id"].is_a?(Integer) && message["id"] < id

        raise BridgeError, "The bridge returned an unexpected response id" unless message["id"] == id

        return message
      end
    end

    def ensure_running
      raise BridgeError, "Bridge is closed" if @closed
      raise BridgeError, "Bridge is not started" unless @started
      raise BridgeError, "Bridge exited with status #{@wait.value.exitstatus}" unless running?
    end
  end
end
