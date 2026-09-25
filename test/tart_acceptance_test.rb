# frozen_string_literal: true

require_relative "test_helper"
require_relative "../script/lib/tart_acceptance"

class TartAcceptanceTest < Minitest::Test
  Acceptance = Wrangle::TartAcceptance

  class FakeShell
    attr_reader :calls, :spawns
    attr_accessor :alive, :fail_command, :guest_preflight, :stop_on_exec

    def initialize(vms = [])
      @vms = vms
      @calls = []
      @spawns = []
      @alive = true
      @guest_preflight = {
        "setup_assistant_running" => false,
        "setup_assistant_persisted" => false
      }
    end

    def call(*argv)
      @calls << argv
      command = argv[1]
      return result(success: false) if command == fail_command

      case command
      when "list"
        result(JSON.generate(@vms))
      when "clone"
        @vms << vm(argv[3], source: "local")
        result
      when "set"
        result
      when "stop"
        selected = @vms.find { |item| item["Name"] == argv[2] }
        selected.merge!("Running" => false, "State" => "stopped")
        result
      when "delete"
        @vms.reject! { |item| item["Name"] == argv[2] }
        result
      when "exec"
        if stop_on_exec
          selected = @vms.find { |item| item["Name"] == argv[2] }
          selected.merge!("Running" => false, "State" => "stopped")
        end
        output = guest_preflight.is_a?(String) ? guest_preflight : JSON.generate(guest_preflight)
        result(output)
      else
        result(success: false)
      end
    end

    def spawn(*argv, log:)
      @spawns << [argv, log]
      selected = @vms.find { |item| item["Name"] == argv.last }
      selected.merge!("Running" => true, "State" => "running")
      42
    end

    def alive?(_pid) = alive

    def vm(name, running: false, source: "local")
      {
        "Name" => name, "State" => running ? "running" : "stopped", "Running" => running,
        "Source" => source, "Disk" => 50, "Size" => 31, "private" => "PRIVATE"
      }
    end

    private

    def result(stdout = "", success: true)
      Acceptance::Shell::Result.new(stdout:, stderr: "PRIVATE STDERR", success:)
    end
  end

  def setup
    @shell = FakeShell.new([FakeShell.new.vm(Acceptance::DEFAULT_BASE),
                            FakeShell.new.vm(Acceptance::ORIGINAL_PROVISIONED),
                            FakeShell.new.vm(Acceptance::DEFAULT_PROVISIONED),
                            FakeShell.new.vm(Acceptance::PI_PROVISIONED)])
    @tick = 0.0
    @manager = Acceptance::Manager.new(
      shell: @shell, tart: "/fixture/tart", log_root: "/tmp/wrangle-tart-test",
      sleeper: ->(_seconds) {}, monotonic: -> { @tick += 0.1 },
      wall_clock: -> { Time.utc(2026, 9, 23, 12) }
    )
  end

  def test_status_is_sanitized_and_reports_absence
    present = @manager.status(name: Acceptance::DEFAULT_BASE)
    missing = @manager.status(name: "missing")

    assert_equal Acceptance::REPORT_SCHEMA, present["schema"]
    assert_equal "stopped", present.dig("vm", "state")
    assert_equal "absent", missing.dig("vm", "state")
    refute_includes JSON.generate(present), "PRIVATE"
  end

  def test_clone_randomizes_identity_and_refuses_collisions
    report = @manager.clone

    assert_equal "wrangle-provisioned-base", Acceptance::ORIGINAL_PROVISIONED
    assert_equal "wrangle-provisioned-base-v2", Acceptance::DEFAULT_PROVISIONED
    assert_equal "wrangle-pi-base", Acceptance::PI_PROVISIONED
    assert_includes Acceptance::PROTECTED_BASES, Acceptance::PI_PROVISIONED
    assert_equal "clone", report["command"]
    assert_equal Acceptance::DEFAULT_PROVISIONED, report.dig("vm", "source_vm")
    assert_includes @shell.calls, ["/fixture/tart", "set", Acceptance::DEFAULT_VM,
                                   "--random-mac", "--random-serial"]
    error = assert_raises(Acceptance::LifecycleError) { @manager.clone }
    assert_match(/already exists/, error.message)
  end

  def test_snapshot_preflights_and_stops_a_running_source_before_preserving_it
    @manager.clone
    @manager.start
    report = @manager.snapshot(target: "fixture-snapshot")

    assert_equal "snapshot", report["command"]
    assert report.dig("vm", "source_preflight", "safe")
    refute @manager.status.dig("vm", "running")
    error = assert_raises(Acceptance::LifecycleError) do
      @manager.snapshot(target: "stopped-snapshot")
    end
    assert_match(/Start .* before preserving/, error.message)
  end

  def test_preflight_refuses_running_or_persisted_setup_assistant
    @manager.clone
    @manager.start
    assert @manager.preflight.dig("vm", "preflight", "safe")

    @shell.guest_preflight = {
      "setup_assistant_running" => true,
      "setup_assistant_persisted" => false
    }
    running = assert_raises(Acceptance::LifecycleError) { @manager.preflight }
    assert_match(/Setup Assistant is running/, running.message)

    @shell.guest_preflight = {
      "setup_assistant_running" => false,
      "setup_assistant_persisted" => true
    }
    persisted = assert_raises(Acceptance::LifecycleError) { @manager.preflight }
    assert_match(/persisted for login restoration/, persisted.message)
  end

  def test_start_stops_a_new_vm_that_fails_preflight
    @manager.clone
    @shell.guest_preflight = {
      "setup_assistant_running" => true,
      "setup_assistant_persisted" => false
    }

    error = assert_raises(Acceptance::LifecycleError) { @manager.start }
    assert_match(/Setup Assistant is running/, error.message)
    refute @manager.status.dig("vm", "running")
  end

  def test_start_reports_when_a_failed_preflight_vm_cannot_be_stopped
    @manager.clone
    @shell.guest_preflight = {
      "setup_assistant_running" => true,
      "setup_assistant_persisted" => false
    }
    @shell.fail_command = "stop"

    error = assert_raises(Acceptance::LifecycleError) { @manager.start }
    assert_match(/failed guest preflight and could not be stopped/, error.message)
  end

  def test_preflight_fails_closed_on_unavailable_or_invalid_guest_output
    @manager.clone
    @manager.start
    @shell.fail_command = "exec"
    unavailable = assert_raises(Acceptance::LifecycleError) { @manager.preflight(timeout: 1) }
    assert_match(/Timed out waiting/, unavailable.message)

    @shell.fail_command = nil
    @shell.guest_preflight = "not-json"
    invalid = assert_raises(Acceptance::LifecycleError) { @manager.preflight }
    assert_equal "Tart guest preflight returned invalid output", invalid.message
  end

  def test_preflight_detects_a_vm_that_stops_during_confirmation
    @manager.clone
    @manager.start
    @shell.stop_on_exec = true

    error = assert_raises(Acceptance::LifecycleError) { @manager.preflight }
    assert_match(/stopped before its guest preflight completed/, error.message)
  end

  def test_start_stop_and_idempotent_transitions
    @manager.clone
    started = @manager.start(headless: true)
    unchanged = @manager.start(headless: true)
    stopped = @manager.stop
    already_stopped = @manager.stop

    assert started.dig("vm", "changed")
    assert started.dig("vm", "headless")
    assert_includes @shell.spawns.first.first, "--no-graphics"
    refute unchanged.dig("vm", "changed")
    assert stopped.dig("vm", "changed")
    refute already_stopped.dig("vm", "changed")
  end

  def test_start_requires_an_existing_vm_and_detects_early_exit
    assert_raises(Acceptance::LifecycleError) { @manager.start(name: "missing") }

    @manager.clone
    @shell.define_singleton_method(:spawn) { |*, **| 42 }
    @shell.alive = false
    error = assert_raises(Acceptance::LifecycleError) { @manager.start }
    assert_match(/exited before/, error.message)
  end

  def test_start_sanitizes_process_errors
    @manager.clone
    @shell.define_singleton_method(:spawn) { |*, **| raise Errno::EACCES, "PRIVATE PATH" }

    error = assert_raises(Acceptance::LifecycleError) { @manager.start }
    assert_equal "Could not start Tart", error.message
  end

  def test_failed_identity_randomization_removes_the_new_clone
    @shell.fail_command = "set"

    error = assert_raises(Acceptance::LifecycleError) { @manager.clone }
    assert_equal "Tart set failed", error.message
    assert_includes @shell.calls, ["/fixture/tart", "delete", Acceptance::DEFAULT_VM]
    assert_equal "absent", @manager.status.dig("vm", "state")
  end

  def test_reset_requires_explicit_replacement_and_protects_bases
    @manager.clone
    assert_raises(Acceptance::LifecycleError) { @manager.reset }
    assert_raises(Acceptance::LifecycleError) do
      @manager.reset(name: Acceptance::DEFAULT_PROVISIONED, source: Acceptance::DEFAULT_BASE, replace: true)
    end
    assert_raises(Acceptance::LifecycleError) do
      @manager.reset(name: Acceptance::ORIGINAL_PROVISIONED,
                     source: Acceptance::DEFAULT_PROVISIONED, replace: true)
    end
    assert_raises(Acceptance::LifecycleError) do
      @manager.reset(name: Acceptance::PI_PROVISIONED,
                     source: Acceptance::DEFAULT_PROVISIONED, replace: true)
    end

    report = @manager.reset(replace: true)
    assert_equal "reset", report["command"]
    assert_includes @shell.calls, ["/fixture/tart", "delete", Acceptance::DEFAULT_VM]
  end

  def test_bootstrap_configures_resources_and_refuses_invalid_values
    report = @manager.bootstrap(source: "registry/image:tag", name: "fresh-base", cpu: 6,
                                memory: 8192, display: "1280x800")

    assert_equal "bootstrap", report["command"]
    assert_includes @shell.calls, ["/fixture/tart", "set", "fresh-base", "--cpu", "6",
                                   "--memory", "8192", "--display", "1280x800", "--display-refit"]
    assert_raises(Acceptance::LifecycleError) do
      @manager.bootstrap(source: "registry/image:tag", name: "bad-base", cpu: 0)
    end
  end

  def test_invalid_names_and_failed_tart_commands_are_sanitized
    assert_raises(Acceptance::LifecycleError) { @manager.status(name: "bad name") }

    failing = FakeShell.new([FakeShell.new.vm(Acceptance::DEFAULT_PROVISIONED)])
    failing.define_singleton_method(:call) do |*argv|
      if argv[1] == "list"
        Acceptance::Shell::Result.new(stdout: JSON.generate(@vms), stderr: "", success: true)
      else
        Acceptance::Shell::Result.new(stdout: "", stderr: "PRIVATE FAILURE", success: false)
      end
    end
    manager = Acceptance::Manager.new(shell: failing, tart: "tart")
    error = assert_raises(Acceptance::LifecycleError) { manager.clone }
    assert_equal "Tart clone failed", error.message
    refute_includes error.message, "PRIVATE"
  end

  def test_cli_help_does_not_require_a_command
    out = StringIO.new
    err = StringIO.new

    assert_equal 0, Acceptance::CLI.run(["--help"], out:, err:, manager: @manager)
    assert_includes out.string, "Commands: status"
    assert_includes out.string, "Default provisioned source: wrangle-provisioned-base-v2"
    assert_empty err.string
  end

  def test_cli_dispatches_preflight
    @manager.clone
    @manager.start
    out = StringIO.new
    err = StringIO.new

    status = Acceptance::CLI.run(["preflight"], out:, err:, manager: @manager)

    assert_equal 0, status
    assert JSON.parse(out.string).dig("vm", "preflight", "safe")
    assert_empty err.string
  end

  def test_cli_dispatches_status_and_rejects_unknown_commands
    out = StringIO.new
    err = StringIO.new
    status = Acceptance::CLI.run(["status", "--name", Acceptance::DEFAULT_BASE],
                                 out:, err:, manager: @manager)

    assert_equal 0, status
    assert_equal "status", JSON.parse(out.string)["command"]
    assert_empty err.string

    out = StringIO.new
    err = StringIO.new
    status = Acceptance::CLI.run(["unknown"], out:, err:, manager: @manager)
    assert_equal 2, status
    assert_match(/Unknown lifecycle command/, err.string)
  end
end
