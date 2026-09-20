# frozen_string_literal: true

require_relative "test_helper"

class MacOSHelperTest < Minitest::Test
  parallelize_me!
  FAKE = File.expand_path("fixtures/fake_macos_helper.rb", __dir__)

  def test_reads_platform_metadata_without_inheriting_provider_secrets
    helper = build(environment: ENV.to_h.merge("JEV_API_KEY" => "must-not-cross"))

    assert_equal "macos", helper.ping["platform"]
    refute helper.ping["secret_present"]
    assert_equal "display-1", helper.displays.fetch(0)["id"]
    assert_equal "w-1", helper.windows(app: "Finder").fetch(0)["id"]
    assert_equal true, helper.windows(app: "Finder", titles: true).fetch(0)["titles"]
    assert_equal "w-1", helper.frontmost["id"]
    assert_equal true, helper.frontmost(titles: true)["titles"]
  end

  def test_enables_accessibility_for_one_process_generation
    result = build.enable_accessibility(pid: 42, process_instance: "proc-42")

    assert_equal 42, result["pid"]
    assert_equal "proc-42", result["process_instance"]
    assert result["changed"]
    assert result["verified"]
  end

  def test_snapshots_and_executes_against_exact_native_scope_evidence
    helper = build
    bounds = { "x" => 0, "y" => 0, "width" => 100, "height" => 100 }
    snapshot = helper.snapshot(pid: 42, process_instance: "proc-42", window_id: "w-1", bounds:)
    target = snapshot.fetch("targets").fetch("@nnative1:e1")

    assert_equal "native-1", snapshot["snapshot_id"]
    assert_equal %w[ax macos_helper_native], snapshot["provenance"]
    result = helper.execute(pid: 42, process_instance: "proc-42", window_id: "w-1", bounds:,
                            target:, operation: "PRESS")
    assert_equal "delivered", result["dispatch"]
    assert_equal "Native Open", result["target"]
  end

  def test_treats_a_malformed_post_dispatch_receipt_as_unknown_delivery
    helper = build("bad-dispatch")
    bounds = { "x" => 0, "y" => 0, "width" => 100, "height" => 100 }

    error = assert_raises(Wrangle::DriverRefusal) do
      helper.execute(pid: 42, process_instance: "proc-42", window_id: "w-1", bounds:,
                     target: { "path" => [0] }, operation: "PRESS")
    end

    assert_equal "NATIVE_AX_FAILURE", error.code
    assert error.delivery_unknown?
    refute error.safe_to_retry?
  end

  def test_validates_inputs_before_calling_the_helper
    helper = build

    assert_raises(ArgumentError) { helper.windows(app: "") }
    assert_raises(ArgumentError) { helper.enable_accessibility(pid: 0, process_instance: "p") }
    assert_raises(ArgumentError) { helper.enable_accessibility(pid: 1, process_instance: nil) }
    assert_raises(ArgumentError) do
      helper.snapshot(pid: 1, process_instance: "p", window_id: "", bounds: {})
    end
    assert_raises(ArgumentError) do
      helper.snapshot(pid: 1, process_instance: "p", window_id: "w-1", bounds: {}, root_target: "bad")
    end
    assert_raises(ArgumentError) do
      helper.execute(pid: 1, process_instance: "p", window_id: "w-1", bounds: {}, target: nil,
                     operation: "PRESS")
    end
  end

  def test_preserves_structured_refusals
    error = assert_raises(Wrangle::DriverRefusal) { build("refusal").ping }

    assert_equal "scope_changed", error.code
    assert_equal "not_delivered", error.delivery
    assert_equal "unsafe", error.retry_disposition
    assert_equal "Attach again", error.suggestion
    assert_equal({ "pid" => 2 }, error.details)
    refute error.safe_to_retry?
  end

  def test_uses_safe_defaults_for_a_bare_refusal
    error = assert_raises(Wrangle::DriverRefusal) { build("bare-refusal").ping }

    assert_equal "DRIVER_ERROR: Driver refused", error.message
    assert_nil error.delivery
  end

  def test_rejects_malformed_replies
    assert_raises(Wrangle::DriverError) { build("invalid").ping }
    assert_raises(Wrangle::DriverError) { build("array").ping }
    assert_raises(Wrangle::DriverError) { build("protocol").ping }
    assert_raises(Wrangle::DriverError) { build("no-value").ping }
    assert_raises(Wrangle::DriverError) { build("incomplete-refusal").ping }
  end

  def test_rejects_success_from_a_failed_process
    error = assert_raises(Wrangle::DriverError) { build("exit-two").ping }

    assert_match(/exited 2/, error.message)
  end

  def test_runner_bounds_stderr_and_response_size
    stderr_runner = runner('$stderr.write("x" * 100_000); print "{}"')
    result = stderr_runner.call("request")

    assert_equal Wrangle::MacOSHelper::STDERR_BYTES, result.stderr.bytesize
    assert result.status.success?

    oversized = runner("print \"x\" * #{Wrangle::MacOSHelper::MAX_RESPONSE_BYTES + 1}")
    assert_raises(Wrangle::DriverError) { oversized.call("request") }
  end

  def test_runner_has_a_hard_deadline
    sleeping = runner("sleep 10", timeout: 0.05)
    stubborn = runner('trap("TERM") {}; sleep 10', timeout: 0.05)

    assert_match(/deadline/, assert_raises(Wrangle::DriverTimeout) { sleeping.call("request") }.message)
    assert_match(/deadline/, assert_raises(Wrangle::DriverTimeout) { stubborn.call("request") }.message)
  end

  def test_runner_reports_a_missing_executable_and_validates_configuration
    missing = Wrangle::MacOSHelper::Runner.new(
      command: "/definitely/missing/macos-helper", environment: {}, timeout: 1
    )

    assert_raises(Wrangle::DriverUnavailable) { missing.call("request") }
    assert_raises(ArgumentError) { Wrangle::MacOSHelper::Runner.new(command: [], environment: {}) }
    assert_raises(ArgumentError) do
      Wrangle::MacOSHelper::Runner.new(command: "echo", environment: {}, timeout: 0)
    end
  end

  private

  def runner(source, timeout: 2)
    Wrangle::MacOSHelper::Runner.new(
      command: [RbConfig.ruby, "--disable-gems", "-e", source], environment: {}, timeout:
    )
  end

  def build(mode = "driver", environment: ENV)
    Wrangle::MacOSHelper.new(
      command: [RbConfig.ruby, "--disable-gems", FAKE, mode], timeout: 2, environment:
    )
  end
end
