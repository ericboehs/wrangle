# frozen_string_literal: true

require "fileutils"
require "json"
require "socket"

module Wrangle
  # Socket accept loop and JSON dispatch for one desktop session.
  module DesktopSessionProtocol
    SOCKET_MODE = 0o600
    SOCKET_DIRECTORY_MODE = 0o700
    # A client must send its one request line within this many seconds of connecting (and never past
    # a parked approval's TTL), so a silent or trickling client cannot hold the session or its lease.
    READ_TIMEOUT = 5.0
    MAX_REQUEST_BYTES = 64 * 1024
    # A parked task session exists for one bound decision. Status is read-only and touches no driver.
    PARKED_OPS = %w[approve decline status].freeze

    # Creates `directory` 0700, or tightens it to 0700 when it already exists and this user owns it.
    def self.private_directory(directory)
      FileUtils.mkdir_p(directory, mode: SOCKET_DIRECTORY_MODE)
      File.chmod(SOCKET_DIRECTORY_MODE, directory)
    rescue Errno::EPERM
      nil # Another user's directory is not ours to tighten.
    end

    private

    # Binds the session socket owner-only. The directory is forced to 0700 when this user owns it and
    # the socket is created under a 0177 umask, so there is no window in which another uid can connect.
    # File modes do not separate processes of the same uid: any of them can still connect.
    def bind_private_socket(path)
      DesktopSessionProtocol.private_directory(File.dirname(path))
      FileUtils.rm_f(path)
      previous = File.umask(0o177)
      begin
        listener = UNIXServer.new(path)
      ensure
        File.umask(previous)
      end
      File.chmod(SOCKET_MODE, path)
      listener
    end

    def serve(server, deadline: nil)
      @serving = true
      File.chmod(SOCKET_MODE, @socket_path)
      loop do
        break if deadline && !socket_ready?(server, deadline)

        client = server.accept
        line = read_request_line(client, deadline)
        next client.close unless line

        request = parse(line)
        client.puts(JSON.generate(dispatch(request)))
        client.close
        break if request["op"] == "close" || @approval_resolved
      end
    ensure
      @serving = false
      server.close
    end

    # One newline-terminated request, or nil when the client stays silent, trickles past the read
    # deadline, closes early, or sends more than MAX_REQUEST_BYTES without a newline.
    def read_request_line(client, deadline)
      stop = monotonic + (@read_timeout || READ_TIMEOUT)
      stop = [stop, deadline].min if deadline
      buffer = String.new(capacity: 4096) # binary until the whole line is in
      until buffer.include?("\n")
        remaining = stop - monotonic
        return nil unless remaining.positive? && client.wait_readable(remaining)

        buffer << client.readpartial(4096) # readable, so this returns data or raises EOFError
        return nil if buffer.bytesize > MAX_REQUEST_BYTES
      end
      buffer[0, buffer.index("\n") + 1].force_encoding(Encoding::UTF_8)
    rescue EOFError, Errno::ECONNRESET
      nil
    end

    def socket_ready?(server, deadline)
      remaining = deadline - monotonic
      remaining.positive? && server.wait_readable(remaining)
    end

    def parse(line)
      request = JSON.parse(line)
      request.is_a?(Hash) ? request : { "op" => "bad" }
    rescue JSON::ParserError
      { "op" => "bad" }
    end

    def dispatch(request)
      return parked_refusal(request) if @parked_approval && !PARKED_OPS.include?(request["op"])

      { "ok" => true, "value" => handle(request) }
    rescue Wrangle::Error => e
      terminal = e.is_a?(ScopeLost) || e.is_a?(DeliveryUnknown) || e.is_a?(DriverUnavailable) ||
                 (e.is_a?(DriverRefusal) && e.delivery_unknown?)
      log_refusal(request, e)
      refusal(e.class.name.split("::").last, e.message, terminal:)
    rescue ArgumentError => e
      log_refusal(request, e)
      refusal("ArgumentError", e.message, terminal: false)
    rescue StandardError => e
      log_refusal(request, e)
      refusal(e.class.name, "internal error: #{e.message} (#{e.backtrace&.first})", terminal: true)
    end

    # Refused before `handle`: no driver call, no proposal, no marker, and the parked approval, its
    # lease, and its TTL are exactly as they were.
    def parked_refusal(request)
      @log&.record("refusal", "operation" => request["op"].to_s[0, 40], "class" => "ParkedSession")
      {
        "ok" => false, "class" => "ParkedSession",
        "error" => "This session is parked for one bound approval; only #{PARKED_OPS.join(", ")} are accepted",
        "allowed_ops" => PARKED_OPS, "terminal" => false, "retryable" => false
      }
    end
  end
end
