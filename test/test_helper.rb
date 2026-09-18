# frozen_string_literal: true

# Before anything else: Coverage has to start before the library it measures is loaded.
require_relative "coverage_report" if ENV["COVERAGE"]

require "json"
require "English"
require "minitest/autorun"
require "tmpdir"

require "wrangle"

# Every test runs against a fake bridge process that speaks the real protocol, so the rules being
# checked are the ones that ship.
module BridgeHelpers
  FAKE_BRIDGE = File.expand_path("fixtures/fake_bridge.rb", __dir__)
  FIXTURE_URL = "https://fixture.test/stays"

  def setup
    super
    @tmpdir = Dir.mktmpdir("wrangle-test")
    @trace = File.join(@tmpdir, "requests.jsonl")
    @configs = 0
    @sessions = []
  end

  def teardown
    @sessions.each do |session|
      session.close
    rescue Wrangle::Error
      nil
    end
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
    super
  end

  def bridge(**config)
    @configs += 1
    path = File.join(@tmpdir, "config-#{@configs}.json")
    File.write(path, JSON.generate(config.merge(trace: @trace)))
    ENV["FAKE_BRIDGE_CONFIG"] = path
    Wrangle::JxaBridge.new(command: [RbConfig.ruby], script: FAKE_BRIDGE, request_timeout: 5, startup_timeout: 10)
  end

  def started(**config)
    bridge(**config).tap(&:start)
  end

  def dedicated(**config)
    track(Wrangle::Safari.new(url: FIXTURE_URL, display: 1, bridge: bridge(**config)))
  end

  def handed_over(**config)
    config[:windows] ||= [{ url: FIXTURE_URL, window_id: 4242, tabs: 5 }]
    track(Wrangle::Safari.new(window_id: 4242, url: FIXTURE_URL, bridge: bridge(**config)))
  end

  def track(session)
    @sessions << session
    session
  end

  def traced(op = nil)
    return [] unless File.exist?(@trace)

    File.readlines(@trace).map { |line| JSON.parse(line) }.select { |r| op.nil? || r["op"] == op }
  end

  def page_ops = traced("eval").map { |request| JSON.parse(request["payload"]) }

  def find(page, label) = page["actions"].find { |action| action["label"] == label }
end
