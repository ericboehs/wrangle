# frozen_string_literal: true

require_relative "test_helper"
require_relative "../script/lib/tart_acceptance"

class TartAcceptanceTest < Minitest::Test
  Acceptance = Wrangle::TartAcceptance

  class FakeShell
    attr_reader :calls, :spawns
    attr_accessor :alive, :fail_command

    def initialize(vms = [])
      @vms = vms
      @calls = []
      @spawns = []
      @alive = true
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
                            FakeShell.new.vm(Acceptance::DEFAULT_PROVISIONED)])
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

    assert_equal "clone", report["command"]
    assert_equal Acceptance::DEFAULT_PROVISIONED, report.dig("vm", "source_vm")
    assert_includes @shell.calls, ["/fixture/tart", "set", Acceptance::DEFAULT_VM,
                                   "--random-mac", "--random-serial"]
    error = assert_raises(Acceptance::LifecycleError) { @manager.clone }
    assert_match(/already exists/, error.message)
  end

  def test_snapshot_requires_a_stopped_source_and_new_target
    @manager.clone
    report = @manager.snapshot(target: "fixture-snapshot")
    assert_equal "snapshot", report["command"]

    @manager.start
    assert_raises(Acceptance::LifecycleError) do
      @manager.snapshot(target: "running-snapshot")
    end
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
