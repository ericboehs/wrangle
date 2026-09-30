# frozen_string_literal: true

require_relative "test_helper"

class MacOSDriverTest < Minitest::Test
  class FakeHelper
    attr_accessor :found_windows, :found_displays, :front_window, :failure, :native_dispatch,
                  :session_locked, :snapshot_failure, :execute_failure, :incomplete_snapshot
    attr_reader :enabled, :native_snapshots, :native_executed

    def initialize
      @found_windows = [window]
      @found_displays = [display]
      @front_window = window
      @native_snapshots = []
      @native_dispatch = "delivered"
    end

    def ping
      raise failure if failure

      { "platform" => "macos", "accessibility" => true, "session_locked" => session_locked == true }
    end

    def windows(app:, titles: false)
      @last_window_request = [app, titles]
      found_windows
    end

    def displays = found_displays
    def frontmost(titles: false) = front_window.merge("titles" => titles)

    def enable_accessibility(pid:, process_instance:)
      @enabled = [pid, process_instance]
      { "changed" => true, "verified" => true, "method" => "manual" }
    end

    def snapshot(pid:, process_instance:, window_id:, bounds:, max_depth:, root_target: nil)
      raise snapshot_failure if snapshot_failure

      @native_snapshots << { pid:, process_instance:, window_id:, bounds:, root_target:, max_depth: }
      return { "snapshot_id" => "broken" } if incomplete_snapshot

      number = @native_snapshots.length
      target = { "path" => [0], "role" => "button", "name" => "Native",
                 "operations" => { "PRESS" => "AXPress" } }
      reference = "@nnative#{number}:e1"
      { "snapshot_id" => "native-#{number}", "complete" => true,
        "window" => { "id" => window_id }, "provenance" => %w[ax macos_helper_native],
        "tree" => { "role" => "window", "children" => [
          { "ref_id" => reference, "role" => "button", "name" => "Native",
            "operations" => ["PRESS"], "target_key" => "native:0:button" }
        ] }, "targets" => { reference => target } }
    end

    def execute(**arguments)
      raise execute_failure if execute_failure

      @native_executed = arguments
      { "dispatch" => native_dispatch, "driver" => "macos_helper_native" }
    end

    def window(bundle: "com.apple.finder")
      bounds = { "x" => 10, "y" => 10, "width" => 50, "height" => 50 }
      { "id" => "w-1", "app_name" => "Finder", "bundle_id" => bundle, "pid" => 42,
        "process_instance" => "proc-42", "bounds" => bounds }
    end

    def display
      { "id" => "display-1", "bounds" => { "x" => 0, "y" => 0, "width" => 100, "height" => 100 } }
    end
  end

  def setup
    @helper = FakeHelper.new
    @driver = Wrangle::MacOSDriver.new(helper: @helper)
  end

  def test_doctor_reports_one_native_driver
    report = @driver.doctor

    assert report["ready"]
    assert_equal "macos_native", report["driver"]
    assert_equal "macos_native", report.dig("capabilities", "window_inventory")
    assert_equal "macos_native_exact_window", report.dig("capabilities", "ax_snapshot")
    assert_equal "macos_native_exact_window", report.dig("capabilities", "ax_dispatch")
    assert_equal 1, report["displays"]
  end

  def test_doctor_reports_lock_and_native_failure
    @helper.session_locked = true
    refute @driver.doctor["ready"]
    assert @driver.doctor["session_locked"]

    @helper.failure = Wrangle::DriverUnavailable.new("missing")
    report = @driver.doctor
    refute report["ready"]
    assert_equal "DriverUnavailable", report["class"]
    assert_equal "missing", report["error"]
  end

  def test_delegates_metadata_discovery
    assert_equal @helper.found_windows, @driver.windows(app: "Finder")
    assert_equal @helper.found_displays, @driver.displays
    assert_equal "w-1", @driver.frontmost(titles: true)["id"]
  end

  def test_attaches_one_exact_window_and_records_its_display
    scope = @driver.attach(window_id: "w-1", app: "Finder")

    assert_match(/\A[0-9a-f-]{36}\z/, scope.id)
    assert_equal "w-1", scope.root
    assert_equal "Finder", scope.app
    assert_equal "com.apple.finder", scope.bundle_id
    assert_equal 42, scope.pid
    assert_equal "proc-42", scope.process_instance
    assert_equal "display-1", scope.display_id
    assert_match(/Z\z/, scope.attached_at)
  end

  def test_attach_fails_closed_on_missing_ambiguous_or_incomplete_windows
    @helper.found_windows = []
    assert_raises(Wrangle::ScopeLost) { @driver.attach(window_id: "w-1", app: "Finder") }

    @helper.found_windows = [@helper.window, @helper.window]
    assert_raises(Wrangle::ScopeLost) { @driver.attach(window_id: "w-1", app: "Finder") }

    @helper.found_windows = [{ "id" => "w-1" }]
    assert_raises(Wrangle::DriverError) { @driver.attach(window_id: "w-1", app: "Finder") }
  end

  def test_attach_allows_a_window_between_known_displays_without_guessing
    @helper.found_windows.first["bounds"] = { "x" => 500, "y" => 500, "width" => 10, "height" => 10 }

    assert_nil @driver.attach(window_id: "w-1", app: "Finder").display_id
  end

  def test_prepare_enables_only_known_electron_process_generation
    finder = @driver.attach(window_id: "w-1", app: "Finder")
    assert_equal "not_electron", @driver.prepare(finder)["reason"]
    assert_nil @helper.enabled

    @helper.found_windows = [@helper.window(bundle: "com.tinyspeck.slackmacgap")]
    slack = @driver.attach(window_id: "w-1", app: "Slack")
    assert @driver.prepare(slack)["verified"]
    assert_equal [42, "proc-42"], @helper.enabled
    assert @driver.prepare(slack)["cached"]
  end

  def test_observes_exact_window_directly_through_native_ax
    scope = @driver.attach(window_id: "w-1", app: "Finder")
    observation = @driver.observe(scope, skeleton: false)

    assert_equal "w-1", observation.dig("scope", "root")
    assert_equal "Native", observation.dig("candidates", 0, "label")
    assert_equal %w[ax macos_helper_native], observation.dig("coverage", "provenance")
    assert_equal "macos_helper_native", observation.dig("observation_setup", "snapshot_source")
    assert_equal 24, @helper.native_snapshots.last[:max_depth]
    refute observation["observation_setup"].key?("fallback")
  end

  def test_drills_only_a_ref_from_the_same_scope_and_snapshot
    scope = @driver.attach(window_id: "w-1", app: "Finder")
    observation = @driver.observe(scope)
    snapshot_id = observation["snapshot_id"]
    reference = observation.dig("candidates", 0, "ref")

    drilled = @driver.drill(scope, ref: reference, snapshot_id:)
    assert_equal "Native", drilled.dig("candidates", 0, "label")
    assert_equal [0], @helper.native_snapshots.last.dig(:root_target, "path")

    error = assert_raises(Wrangle::DriverRefusal) do
      @driver.drill(scope, ref: "@nmissing:e1", snapshot_id:)
    end
    assert_equal "STALE_REF", error.code
  end

  def test_native_refs_are_scope_bound_and_evicted
    scope = @driver.attach(window_id: "w-1", app: "Finder")
    reference = @driver.observe(scope).dig("candidates", 0, "ref")
    receipt = @driver.execute(scope, operation: "PRESS", ref: reference)
    assert_equal "delivered", receipt["dispatch"]
    assert_equal "PRESS", @helper.native_executed[:operation]

    other_scope = @driver.attach(window_id: "w-1", app: "Finder")
    assert_equal "not_delivered", @driver.execute(other_scope, operation: "PRESS", ref: reference)["dispatch"]

    Wrangle::MacOSDriver::NATIVE_SNAPSHOT_LIMIT.times { @driver.observe(scope) }
    assert_equal "not_delivered", @driver.execute(scope, operation: "PRESS", ref: reference)["dispatch"]
  end

  def test_observation_revalidates_process_identity
    scope = @driver.attach(window_id: "w-1", app: "Finder")
    @helper.found_windows.first["process_instance"] = "replacement"
    assert_raises(Wrangle::ScopeLost) { @driver.observe(scope) }

    @helper.found_windows = [@helper.window, @helper.window]
    assert_raises(Wrangle::ScopeLost) { @driver.observe(scope) }
  end

  def test_execute_maps_native_delivery_without_retrying
    scope = @driver.attach(window_id: "w-1", app: "Finder")
    reference = @driver.observe(scope).dig("candidates", 0, "ref")

    @helper.execute_failure = Wrangle::DriverRefusal.new(
      "STALE_REF", "moved", delivery: "not_delivered", retry_disposition: "safe"
    )
    refused = @driver.execute(scope, operation: "PRESS", ref: reference)
    assert_equal "not_delivered", refused["dispatch"]
    assert refused["retry_safe"]

    @helper.execute_failure = Wrangle::DriverRefusal.new("TIMEOUT", "late", delivery: "unknown")
    assert_equal "delivery_unknown", @driver.execute(scope, operation: "PRESS", ref: reference)["dispatch"]

    @helper.execute_failure = Wrangle::DriverRefusal.new("POLICY", "no")
    assert_equal "refused", @driver.execute(scope, operation: "PRESS", ref: reference)["dispatch"]
  end

  def test_rejects_incomplete_native_snapshot
    @helper.incomplete_snapshot = true
    scope = @driver.attach(window_id: "w-1", app: "Finder")

    assert_raises(Wrangle::DriverError) { @driver.observe(scope) }
  end

  def test_close_invalidates_native_refs
    scope = @driver.attach(window_id: "w-1", app: "Finder")
    reference = @driver.observe(scope).dig("candidates", 0, "ref")

    @driver.close

    assert_equal "not_delivered", @driver.execute(scope, operation: "PRESS", ref: reference)["dispatch"]
  end
end
