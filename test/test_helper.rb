# frozen_string_literal: true

# Before anything else: Coverage has to start before the library it measures is loaded.
require_relative "coverage_report" if ENV["COVERAGE"]

require "json"
require "English"
require "etc"

# Most of the parallel tests wait on isolated child processes or sockets rather than consuming Ruby
# CPU. A modest oversubscription keeps those waits off the critical path without creating an
# unbounded worker pool on large machines. Callers can still set MT_CPU explicitly.
ENV["MT_CPU"] ||= (Etc.nprocessors * 2).clamp(4, 16).to_s
require "minitest/autorun"
require "tmpdir"

require "wrangle"

# No test may reach the network. The session server builds a Jev client from the environment when it
# is not given one, so a test that forgets to pass a fake quietly spends real money against the real
# endpoint — which is exactly how this was found. Unsetting the keys turns that mistake into a
# ConfigurationError instead of a bill. Jev's own tests set them back for the lines that need them.
ENV.delete("JEV_API_KEY")
ENV.delete("TYPESAFE_API_KEY")

# Production timing remains monotonic wall time. Tests advance the same deadlines deterministically
# while yielding briefly so the bridge and decision threads still exercise their real coordination.
class AcceleratedClock
  def initialize(scale: 0.02)
    @now = 0.0
    @scale = scale
    @mutex = Mutex.new
  end

  def now = @mutex.synchronize { @now }

  def sleep(seconds)
    @mutex.synchronize { @now += seconds }
    Kernel.sleep(seconds * @scale)
    Thread.pass
  end
end

# Semantic browser tests keep one real JSONL bridge process per Minitest worker. Each test resets the
# fake application before use, retaining the process/protocol boundary without paying Ruby startup
# for every example. Transport-failure tests opt out and own a disposable process.
class ReusableJxaBridge
  @bridges = []
  @lock = Mutex.new

  class << self
    def acquire(command:, script:, startup_timeout:)
      active = Thread.current.thread_variable_get(:wrangle_test_jxa_bridge)
      return active if active&.running?

      active = Wrangle::JxaBridge.new(command:, script:, request_timeout: 5, startup_timeout:)
      active.start
      Thread.current.thread_variable_set(:wrangle_test_jxa_bridge, active)
      @lock.synchronize { @bridges << active }
      active
    end

    def shutdown
      @lock.synchronize { @bridges.dup }.each do |bridge|
        bridge.request("__configure", config: {}) if bridge.running?
        bridge.close
      rescue Wrangle::Error
        bridge.close
      end
    end
  end

  def initialize(command:, script:, config:, trace:, request_timeout:, startup_timeout:)
    @bridge = self.class.acquire(command:, script:, startup_timeout:)
    @config = config.merge(trace:)
    @trace = trace
    @request_timeout = request_timeout
    @startup_timeout = startup_timeout
    @started = false
    @closed = false
  end

  def start
    raise Wrangle::BridgeError, "Bridge is already started" if @started

    FileUtils.rm_f(@trace)
    @bridge.request("__configure", timeout: @startup_timeout, config: @config)
    ping = @bridge.request("ping", timeout: @startup_timeout)
    @bridge.request(
      "scripts", timeout: @startup_timeout,
                 page: File.read(File.join(Wrangle::JxaBridge::SCRIPTS, "page.js")),
                 snapshot: File.read(File.join(Wrangle::JxaBridge::SCRIPTS, "snapshot.js"))
    )
    @started = true
    ping
  end

  def request(op, timeout: nil, **parameters)
    ensure_running
    @bridge.request(op, timeout: timeout || @request_timeout, **parameters)
  end

  def evaluate(scope, page_request, verify: false, timeout: nil)
    ensure_running
    @bridge.evaluate(scope, page_request, verify:, timeout: timeout || @request_timeout)
  end

  def running? = @started && !@closed && @bridge.running?
  def close = @closed = true
  def pid = @bridge.pid
  def stderr = @bridge.stderr

  private

  def ensure_running
    raise Wrangle::BridgeError, "Bridge is closed" if @closed
    raise Wrangle::BridgeError, "Bridge is not started" unless @started
  end
end

Minitest.after_run { ReusableJxaBridge.shutdown }

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
    @clock = AcceleratedClock.new
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

  def bridge(request_timeout: 5, reusable: true, **config)
    @configs += 1
    path = File.join(@tmpdir, "config-#{@configs}.json")
    File.write(path, JSON.generate(config.merge(trace: @trace)))
    command = ["/usr/bin/env", "FAKE_BRIDGE_CONFIG=#{path}", RbConfig.ruby, "--disable-gems"]
    return Wrangle::JxaBridge.new(command:, script: FAKE_BRIDGE, request_timeout:, startup_timeout: 10) unless reusable

    ReusableJxaBridge.new(command:, script: FAKE_BRIDGE, config:, trace: @trace,
                          request_timeout:, startup_timeout: 10)
  end

  def started(**config)
    bridge(**config).tap(&:start)
  end

  def dedicated(request_timeout: 5, reusable: true, **config)
    active = bridge(request_timeout:, reusable:, **config)
    track(Wrangle::Safari.new(url: FIXTURE_URL, display: 1, bridge: active, timing: @clock))
  end

  def handed_over(request_timeout: 5, reusable: true, **config)
    config[:windows] ||= [{ url: FIXTURE_URL, window_id: 4242, tabs: 5 }]
    active = bridge(request_timeout:, reusable:, **config)
    track(Wrangle::Safari.new(window_id: 4242, url: FIXTURE_URL, bridge: active, timing: @clock))
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
