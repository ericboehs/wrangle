# frozen_string_literal: true

require "json"
require "open3"

require_relative "errors"

module Wrangle
  # Audited macOS primitives for exact-window discovery, bounded AX observation, and dispatch.
  #
  # The Swift helper receives one JSON value as data, never generated source. Every action comes
  # from an observed target and revalidates process, window, path, and signature before its one
  # allowed dispatch. Provider keys and the rest of the caller's environment never cross the boundary.
  class MacOSHelper
    SCRIPT = File.expand_path("macos/helper.swift", __dir__)
    COMMAND = ["/usr/bin/swift", SCRIPT].freeze
    PROTOCOL_MAJOR = 1
    DISPATCHES = %w[delivered not_delivered refused delivery_unknown].freeze
    SAFE_ENV = %w[HOME PATH TMPDIR LANG LC_ALL LC_CTYPE].freeze
    MAX_RESPONSE_BYTES = 8 * 1024 * 1024
    STDERR_BYTES = 32 * 1024
    DEFAULT_TIMEOUT = 30

    # Runs the helper without a shell, with bounded output and a hard deadline.
    class Runner
      Result = Data.define(:stdout, :stderr, :status)

      def initialize(command:, environment:, timeout: DEFAULT_TIMEOUT)
        @command = Array(command)
        @environment = environment
        @timeout = timeout
        raise ArgumentError, "macOS helper command cannot be empty" if @command.empty?
        raise ArgumentError, "macOS helper timeout must be positive" unless @timeout.to_f.positive?
      end

      def call(*arguments)
        options = { pgroup: true, unsetenv_others: true }
        Open3.popen3(@environment, *@command, *arguments, **options) do |input, output, error, wait|
          input.close
          stdout = reader(output, MAX_RESPONSE_BYTES)
          stderr = reader(error, STDERR_BYTES, truncate: true)
          expire(wait) unless wait.join(@timeout)
          Result.new(stdout: stdout.value, stderr: stderr.value, status: wait.value)
        ensure
          output.close unless output.closed?
          error.close unless error.closed?
        end
      rescue Errno::ENOENT
        raise DriverUnavailable, "macOS helper is not installed or is not executable"
      end

      private

      def reader(io, limit, truncate: false)
        thread = Thread.new do
          buffer = +""
          loop do
            chunk = io.readpartial(16 * 1024)
            if truncate
              buffer << chunk.byteslice(0, limit - buffer.bytesize) if buffer.bytesize < limit
            else
              buffer << chunk
              raise DriverError, "macOS helper response exceeded #{limit} bytes" if buffer.bytesize > limit
            end
          end
        rescue EOFError
          buffer
        ensure
          io.close
        end
        thread.report_on_exception = false
        thread
      end

      def expire(wait)
        Process.kill("TERM", -wait.pid)
        unless wait.join(0.25)
          Process.kill("KILL", -wait.pid)
          wait.join
        end
        raise DriverTimeout, "macOS helper exceeded the #{@timeout}s deadline"
      rescue Errno::ESRCH, Errno::ECHILD
        raise DriverTimeout, "macOS helper exceeded the #{@timeout}s deadline"
      end
    end

    attr_reader :command

    def initialize(command: nil, timeout: DEFAULT_TIMEOUT, runner: nil, environment: ENV)
      @command = Array(command || environment["WRANGLE_MACOS_HELPER"] || COMMAND)
      @runner = runner || Runner.new(command: @command, environment: filtered_environment(environment), timeout:)
    end

    def ping = request("ping")
    def displays = request("displays").fetch("displays")

    def windows(app:, titles: false)
      raise ArgumentError, "An application is required for scoped window discovery" if app.to_s.empty?

      request("windows", app:, titles:).fetch("windows")
    end

    def frontmost(titles: false) = request("frontmost", titles:).fetch("window")

    def enable_accessibility(pid:, process_instance:)
      validate_process!(pid, process_instance)
      request("enable_accessibility", pid:, process_instance:)
    end

    def snapshot(pid:, process_instance:, window_id:, bounds:, root_target: nil, max_depth: 18)
      validate_scope!(pid, process_instance, window_id, bounds)
      unless root_target.nil? || root_target.is_a?(Hash)
        raise ArgumentError, "Native AX snapshot root must be an observed target"
      end

      request("snapshot", pid:, process_instance:, window_id:, bounds:, root_target:, max_depth:)
    end

    def execute(pid:, process_instance:, window_id:, bounds:, target:, operation:, text: nil)
      validate_scope!(pid, process_instance, window_id, bounds)
      raise ArgumentError, "Native AX execution requires an observed target" unless target.is_a?(Hash)

      result = request("execute", pid:, process_instance:, window_id:, bounds:, target:, operation:, text:)
      unless result.is_a?(Hash) && DISPATCHES.include?(result["dispatch"])
        raise DriverError, "Native AX helper returned an invalid dispatch receipt"
      end

      result
    rescue DriverRefusal, DriverUnavailable
      raise
    rescue DriverError => e
      raise DriverRefusal.new("NATIVE_AX_FAILURE", "Native AX delivery could not be determined: #{e.class}",
                              delivery: "unknown", retry_disposition: "unsafe")
    end

    def request(op, **parameters)
      result = @runner.call(JSON.generate(parameters.merge(op:)))
      envelope = parse(result.stdout)
      validate!(envelope)
      refusal!(envelope) unless envelope["ok"]
      unless result.status.success?
        raise DriverError, "macOS helper exited #{result.status.exitstatus} after reporting success"
      end

      envelope.fetch("value")
    end

    private

    def validate_process!(pid, process_instance)
      valid = pid.is_a?(Integer) && pid.positive? && process_instance.is_a?(String) && !process_instance.empty?
      return if valid

      raise ArgumentError, "Accessibility setup requires a PID and process instance"
    end

    def validate_scope!(pid, process_instance, window_id, bounds)
      validate_process!(pid, process_instance)
      return if window_id.is_a?(String) && !window_id.empty? && bounds.is_a?(Hash)

      raise ArgumentError, "Native AX operation requires an exact window and bounds"
    end

    def filtered_environment(source)
      SAFE_ENV.each_with_object({}) { |key, kept| kept[key] = source[key] if source.key?(key) }
    end

    def parse(output)
      parsed = JSON.parse(output)
      raise DriverError, "macOS helper returned something other than one JSON object" unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError
      raise DriverError, "macOS helper returned invalid JSON"
    end

    def validate!(envelope)
      major = Integer(envelope["version"].to_s.split(".").first, exception: false)
      valid = major == PROTOCOL_MAJOR && [true, false].include?(envelope["ok"])
      raise DriverError, "macOS helper returned an incompatible envelope" unless valid
      raise DriverError, "macOS helper returned no value" if envelope["ok"] && !envelope["value"].is_a?(Hash)
    end

    def refusal!(envelope)
      error = envelope["error"]
      raise DriverError, "macOS helper returned an incomplete refusal" unless error.is_a?(Hash)

      disposition = error["disposition"].is_a?(Hash) ? error["disposition"] : {}
      raise DriverRefusal.new(error.fetch("code", "DRIVER_ERROR"), error.fetch("message", "Driver refused"),
                              delivery: disposition["delivery"], retry_disposition: disposition["retry"],
                              suggestion: error["suggestion"], details: error["details"])
    end
  end
end
