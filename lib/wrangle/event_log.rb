# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Wrangle
  # Compact, owner-only JSONL audit events. Callers pass metadata, never pixels or literal values.
  class EventLog
    RETENTION = 7 * 24 * 60 * 60

    def initialize(session:, root: nil, now: Time.now)
      home = ENV["WRANGLE_HOME"] || File.join(Dir.home, ".wrangle")
      @root = root || File.join(home, "logs")
      FileUtils.mkdir_p(@root, mode: 0o700)
      File.chmod(0o700, @root)
      prune(now)
      safe_session = session.to_s.gsub(/[^a-zA-Z0-9_.-]/, "_")[0, 80]
      @path = File.join(@root, "#{now.utc.strftime("%Y%m%d")}-#{safe_session}-#{Process.pid}.jsonl")
    end

    attr_reader :path

    def record(type, fields = nil, durable: false, **implicit_fields)
      fields = (fields || {}).merge(implicit_fields)
      event = { "at" => Time.now.utc.iso8601(3), "event" => type }.merge(fields.compact)
      File.open(@path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
        file.flock(File::LOCK_EX)
        file.puts(JSON.generate(event))
        file.flush
        file.fsync if durable
      end
      File.open(@root, File::RDONLY, &:fsync) if durable
      event
    end

    private

    def prune(now)
      Dir.each_child(@root) do |name|
        next if name.end_with?(".pinned")

        path = File.join(@root, name)
        next unless File.file?(path)
        next unless now - File.mtime(path) > RETENTION

        File.unlink(path)
      end
    end
  end
end
