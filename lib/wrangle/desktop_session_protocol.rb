# frozen_string_literal: true

require "fileutils"
require "json"
require "socket"

module Wrangle
  # Socket accept loop and JSON dispatch for one desktop session.
  module DesktopSessionProtocol
    SOCKET_MODE = 0o600
    SOCKET_DIRECTORY_MODE = 0o700

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
        line = client.gets
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

    def socket_ready?(server, deadline)
      remaining = deadline - monotonic
      remaining.positive? && server.wait_readable(remaining)
    end

    def parse(line)
      JSON.parse(line)
    rescue JSON::ParserError
      { "op" => "bad" }
    end

    def dispatch(request)
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
  end
end
