# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

require_relative "errors"

module Wrangle
  # Cross-session exclusive ownership for root surfaces.
  class ScopeRegistry
    Lease = Data.define(:path, :token, :mode)
    Dispatch = Data.define(:path, :token)

    def initialize(root: nil)
      home = ENV["WRANGLE_HOME"] || File.join(Dir.home, ".wrangle")
      @root = root || File.join(home, "scopes")
      FileUtils.mkdir_p(@root, mode: 0o700)
      File.chmod(0o700, @root)
    end

    def acquire(scope, mode: "exclusive")
      valid = %w[exclusive cooperative].include?(mode)
      raise ArgumentError, "Concurrency must be exclusive or cooperative" unless valid

      ensure_no_unresolved_dispatch!(scope)
      return Lease.new(path: nil, token: nil, mode:) if mode == "cooperative"

      token = SecureRandom.hex(16)
      path = path_for(scope)
      payload = { "pid" => Process.pid, "token" => token, "scope_id" => scope.id,
                  "root" => scope.root, "driver" => "macos" }
      create(path, payload)
      Lease.new(path:, token:, mode:)
    rescue Errno::EEXIST
      reclaim(path) ? retry : raise(ScopeBusy, "Root surface #{scope.root} is held by another exclusive session")
    end

    def release(lease)
      return unless lease&.path && File.file?(lease.path)

      stored = read(lease.path)
      File.unlink(lease.path) if stored["token"] == lease.token
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end

    # A durable marker crosses the only dangerous gap: process death after dispatch begins but before
    # a receipt exists. It contains no labels or text, and is never reclaimed merely because its PID died.
    def begin_dispatch(scope, proposal_id:, revision:, operation:)
      ensure_no_unresolved_dispatch!(scope)
      token = SecureRandom.hex(16)
      path = dispatch_path_for(scope)
      payload = { "pid" => Process.pid, "token" => token, "scope_id" => scope.id,
                  "proposal_id" => proposal_id, "revision" => revision, "operation" => operation,
                  "started_at" => Time.now.utc.iso8601(3) }
      create(path, payload)
      Dispatch.new(path:, token:)
    rescue Errno::EEXIST
      raise DeliveryUnknown, unresolved_dispatch_message
    end

    def finish_dispatch(dispatch)
      return unless dispatch&.path

      stat = File.lstat(dispatch.path)
      raise DeliveryUnknown, unresolved_dispatch_message unless stat.file? && !stat.symlink?

      stored = read(dispatch.path)
      raise DeliveryUnknown, unresolved_dispatch_message unless stored["token"] == dispatch.token

      File.unlink(dispatch.path)
      sync_root
    rescue Errno::ENOENT, JSON::ParserError
      raise DeliveryUnknown, unresolved_dispatch_message
    end

    private

    def path_for(scope) = File.join(@root, "#{scope_digest(scope)}.json")
    def dispatch_path_for(scope) = File.join(@root, "#{scope_digest(scope)}.dispatch.json")

    def scope_digest(scope)
      identity = ["macos", scope.pid, scope.process_instance, scope.root].join("\0")
      Digest::SHA256.hexdigest(identity)
    end

    def create(path, payload)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.generate(payload))
        file.flush
        file.fsync
      end
      sync_root
    end

    def ensure_no_unresolved_dispatch!(scope)
      path = dispatch_path_for(scope)
      return unless File.exist?(path) || File.symlink?(path)

      stat = File.lstat(path)
      raise DeliveryUnknown, unresolved_dispatch_message unless stat.file? && !stat.symlink?

      read(path)
      raise DeliveryUnknown, unresolved_dispatch_message
    rescue Errno::ENOENT
      nil
    rescue JSON::ParserError
      raise DeliveryUnknown, unresolved_dispatch_message
    end

    def unresolved_dispatch_message
      "A previous action may have been delivered; inspect the application before starting another task"
    end

    def sync_root
      File.open(@root, File::RDONLY, &:fsync)
    end

    def reclaim(path)
      stat = File.lstat(path)
      raise ScopeBusy, "Scope lease is not a regular owner-only file" unless stat.file? && !stat.symlink?

      stored = read(path)
      return false if process_alive?(stored["pid"])

      File.unlink(path)
      true
    rescue Errno::ENOENT
      true
    rescue JSON::ParserError
      raise ScopeBusy, "Scope lease is unreadable; remove #{path} after checking for a live session"
    end

    def read(path)
      JSON.parse(File.read(path, 4096))
    end

    def process_alive?(pid)
      return false unless pid.is_a?(Integer) && pid.positive?

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end
  end
end
