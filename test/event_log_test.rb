# frozen_string_literal: true

require_relative "test_helper"

class EventLogTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("wrangle-log")
  end

  def teardown
    FileUtils.remove_entry(@directory) if File.directory?(@directory)
  end

  def test_writes_compact_owner_only_json_lines
    log = Wrangle::EventLog.new(session: "unsafe/session", root: @directory)
    log.record("observe", { "revision" => "abc", "candidates" => 3 }, durable: true)
    log.record("default")

    assert_equal 0o600, File.stat(log.path).mode & 0o777
    assert_equal 0o700, File.stat(@directory).mode & 0o777
    events = File.readlines(log.path).map { |line| JSON.parse(line) }
    assert_equal "observe", events.first["event"]
    assert_equal 3, events.first["candidates"]
    assert_equal "default", events.last["event"]
    refute_match(%r{unsafe/session}, log.path)
  end

  def test_prunes_unpinned_files_older_than_seven_days
    old = File.join(@directory, "old.jsonl")
    recent = File.join(@directory, "recent.jsonl")
    pinned = File.join(@directory, "keep.pinned")
    [old, recent, pinned].each { |path| File.write(path, "{}\n") }
    Dir.mkdir(File.join(@directory, "exported"))
    now = Time.utc(2026, 9, 18, 12)
    File.utime(now - Wrangle::EventLog::RETENTION - 1, now - Wrangle::EventLog::RETENTION - 1, old)
    File.utime(now - 60, now - 60, recent)
    File.utime(now - Wrangle::EventLog::RETENTION - 1, now - Wrangle::EventLog::RETENTION - 1, pinned)

    Wrangle::EventLog.new(session: "test", root: @directory, now:)

    refute File.exist?(old)
    assert File.exist?(recent)
    assert File.exist?(pinned)
  end
end
