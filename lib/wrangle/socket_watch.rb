# frozen_string_literal: true

require "fileutils"
require "socket"

module Wrangle
  # A session server's listening socket, and whether anyone can still reach it.
  #
  # A server is reachable only through its socket file. Once that file is deleted (its temporary
  # directory cleaned up by a test that failed before sending `close`, say) or replaced by a newer
  # server bound at the same path, no client can connect again, and a server blocked in `accept`
  # would wait for one forever. Waiting in slices and checking the file between them lets the server
  # notice and shut down, and lets shutdown leave a successor's files alone.
  class SocketWatch
    INTERVAL = 5.0

    # Binds the socket, owner-only. The caller clears any stale file at the path first.
    def initialize(path, interval: INTERVAL)
      @path = path
      @interval = interval
      @server = UNIXServer.new(path)
      File.chmod(0o600, path)
      @identity = identity
    end

    # The next client, or nil once the socket file is no longer this server's.
    def accept
      loop do
        return @server.accept if @server.wait_readable(@interval)
        return nil unless ours?
      end
    end

    def ours? = identity == @identity

    # Stops listening and removes the socket and its pid file, but only where they still belong to
    # this server.
    def release
      @server.close unless @server.closed?
      FileUtils.rm_f(@path) if ours?
      pid_file = "#{@path}.pid"
      FileUtils.rm_f(pid_file) if File.exist?(pid_file) && File.read(pid_file).strip == Process.pid.to_s
    rescue SystemCallError
      nil
    end

    private

    def identity
      stat = File.lstat(@path)
      [stat.dev, stat.ino]
    rescue SystemCallError
      nil
    end
  end
end
