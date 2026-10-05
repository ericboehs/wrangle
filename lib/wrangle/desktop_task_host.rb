# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"
require "securerandom"

require_relative "desktop_session_protocol"
require_relative "desktop_task"
require_relative "errors"
require_relative "session_server"

module Wrangle
  # Runs one real desktop task in a child process so a consequential stop can outlive the CLI.
  #
  # The child owns the DesktopSessionServer, the exclusive lease, and the in-memory proposal. It
  # writes the task reply to the parent over a pipe as soon as the result exists, and then, only when
  # an approval is parked, keeps serving the session socket until that approval resolves or its TTL
  # elapses. The parent returns the reply immediately. Nothing about the proposal touches disk.
  module DesktopTaskHost
    TASK_KEYS = %w[app goal literals steps min_confidence concurrency provider_options teach no_skill].freeze

    module_function

    # Parent side. `exe` is the wrangle executable to re-enter with the hidden child command.
    def run(arguments, exe:, session: nil)
      session ||= "task-#{SecureRandom.hex(6)}"
      socket = SessionServer.socket_path(session)
      raise ArgumentError, "A session named #{session.inspect} is already running" if
        SessionClient.new(socket).running?

      log = private_log(socket, session)
      reader, writer = IO.pipe
      pid = Process.spawn(
        RbConfig.ruby, exe, "__task_park", socket, JSON.generate(arguments.slice(*TASK_KEYS)),
        writer.fileno.to_s, writer => writer, out: [log, "a", 0o600], err: [log, "a", 0o600], pgroup: true
      )
      writer.close
      Process.detach(pid)
      line = reader.gets
      raise Error, "The desktop task exited without a result. Last output:\n#{tail(log)}" unless line

      JSON.parse(line)
    ensure
      reader&.close
      writer&.close unless writer.nil? || writer.closed?
    end

    # The session directory is owner-only, and so is the child's output log.
    def private_log(socket, session)
      directory = File.dirname(socket)
      DesktopSessionProtocol.private_directory(directory)
      log = File.join(directory, "#{session}.log")
      File.open(log, File::WRONLY | File::CREAT | File::APPEND, 0o600) { |file| file.chmod(0o600) }
      log
    end

    # Child side. Writes exactly one JSON reply line to `fd`, then serves a parked approval if any.
    def serve(socket, json, pipe_fd, task: DesktopTask.new)
      io = IO.new(Integer(pipe_fd), "w")
      io.sync = true
      io.close_on_exec = true # Helper processes must not hold the parent's reply pipe open.
      reply = lambda do |value|
        next if io.closed?

        io.puts(JSON.generate(value))
        io.close
      end
      notify = ->(value) { reply.call("ok" => true, "value" => value) }
      result = task.run(**keywords(JSON.parse(json)), socket_path: socket, on_ready: notify)
      reply.call("ok" => true, "value" => result)
    rescue Wrangle::Error, ArgumentError => e
      reply&.call(failure(e))
    ensure
      io.close if io && !io.closed?
    end

    def keywords(arguments)
      arguments.slice(*TASK_KEYS).to_h { |key, value| [key.to_sym, value] }
    end

    def failure(error)
      { "ok" => false, "class" => error.class.name.split("::").last, "error" => error.message,
        "terminal" => true, "retryable" => false }
    end

    def tail(log) = File.exist?(log) ? File.readlines(log).last(12).join : "(no output)"
  end
end
