# frozen_string_literal: true

require_relative "test_helper"

class TartGuestDriverTest < Minitest::Test
  Status = Data.define(:successful) do
    def success? = successful
  end

  class FakeRunner
    def initialize(result)
      @result = result
    end

    def call = @result
  end

  class FakeGuard
    attr_reader :instance, :calls

    def initialize(instance: "tart-guest-v1:fixture-vm:1:2")
      @instance = instance
      @calls = 0
    end

    def around
      @calls += 1
      yield
    end
  end

  class FakeHelper
    attr_reader :calls

    def initialize
      @calls = []
    end

    def ping = record(:ping, "platform" => "macos", "accessibility" => true, "session_locked" => false)
    def displays = record(:displays, [{ "id" => "display-1" }])

    def windows(app:, titles: false)
      record([:windows, app, titles], [{ "id" => "w-1", "process_instance" => "guest-process" }])
    end

    def frontmost(titles: false) = record([:frontmost, titles], { "id" => "w-1" })

    def enable_accessibility(pid:, process_instance:)
      record([:enable, pid, process_instance], { "verified" => true })
    end

    def snapshot(**arguments) = record([:snapshot, arguments], { "snapshot_id" => "one" })

    private

    def record(call, value)
      @calls << call
      value
    end
  end

  class FakeDriver
    attr_reader :closed

    def doctor = { "ready" => true, "driver" => "macos_native" }
    def windows(app:, titles: false) = [{ "app" => app, "titles" => titles }]
    def displays = [{ "id" => "display-1" }]
    def frontmost(titles: false) = { "titles" => titles }

    def attach(window_id:, app:)
      Wrangle::MacOSDriver::Scope.new(
        id: "scope", root: window_id, app:, bundle_id: "bundle", pid: 42,
        process_instance: "tart-guest-v1:fixture-vm:1:2/guest-process",
        bounds: {}, display_id: "display-1", attached_at: "now"
      )
    end

    def observe(scope, skeleton: true) = { "scope" => scope, "skeleton" => skeleton }
    def drill(scope, ref:, snapshot_id:) = { "scope" => scope, "ref" => ref, "snapshot_id" => snapshot_id }
    def close = @closed = true
  end

  def test_vm_binds_an_exact_running_name_and_guest_boot_generation
    factory, commands = runner_factory
    vm = Wrangle::TartVM.new(name: "fixture-vm", tart: "/fixture/tart", runner_factory: factory)

    assert_equal "tart-guest-v1:fixture-vm:1790200000:123456", vm.instance
    assert_equal ["/fixture/tart", "list", "--format", "json"], commands[0]
    assert_equal ["/fixture/tart", "exec", "fixture-vm", "/usr/sbin/sysctl", "-n", "kern.boottime"],
                 commands[1]
  end

  def test_vm_guard_verifies_the_same_boot_around_a_read
    factory, commands = runner_factory
    vm = Wrangle::TartVM.new(name: "fixture-vm", runner_factory: factory)

    assert_equal(:observed, vm.around { :observed })
    assert_equal 6, commands.length
  end

  def test_vm_uses_the_bounded_process_runner_by_default
    tart = File.expand_path("fixtures/fake_tart.rb", __dir__)
    vm = Wrangle::TartVM.new(name: "fixture-vm", tart:)

    assert_equal "tart-guest-v1:fixture-vm:1790200000:123456", vm.instance
  end

  def test_vm_rejects_invalid_names_stopped_guests_and_bad_boot_identity
    assert_raises(ArgumentError) { Wrangle::TartVM.new(name: "bad name") }
    assert_raises(ArgumentError) { Wrangle::TartVM.new(name: "fixture-vm", tart: "") }

    stopped, = runner_factory(running: false)
    assert_raises(Wrangle::DriverUnavailable) do
      Wrangle::TartVM.new(name: "fixture-vm", runner_factory: stopped)
    end

    malformed, = runner_factory(boot: "not a boot timestamp")
    assert_raises(Wrangle::DriverError) do
      Wrangle::TartVM.new(name: "fixture-vm", runner_factory: malformed)
    end
  end

  def test_vm_rejects_invalid_inventory_and_unavailable_transport
    invalid_json = fixed_runner_factory(stdout: "{")
    assert_raises(Wrangle::DriverError) do
      Wrangle::TartVM.new(name: "fixture-vm", runner_factory: invalid_json)
    end

    ["{}", "[1]"].each do |inventory|
      malformed = fixed_runner_factory(stdout: inventory)
      assert_raises(Wrangle::DriverError) do
        Wrangle::TartVM.new(name: "fixture-vm", runner_factory: malformed)
      end
    end

    unavailable = fixed_runner_factory(stdout: "", successful: false)
    assert_raises(Wrangle::DriverUnavailable) do
      Wrangle::TartVM.new(name: "fixture-vm", runner_factory: unavailable)
    end
  end

  def test_vm_loses_scope_when_the_guest_reboots
    factory, = runner_factory(boots: ["{ sec = 1, usec = 2 }", "{ sec = 3, usec = 4 }"])
    vm = Wrangle::TartVM.new(name: "fixture-vm", runner_factory: factory)

    error = assert_raises(Wrangle::DriverRefusal) { vm.verify! }
    assert_equal "scope_changed", error.code
    assert_equal "not_delivered", error.delivery
    refute error.safe_to_retry?
  end

  def test_vm_maps_post_attachment_transport_loss_to_scope_change
    running = true
    factory = lambda do |command|
      stdout = if command[1] == "list"
                 JSON.generate([{ "Name" => "fixture-vm", "Running" => running }])
               else
                 "{ sec = 1, usec = 2 }"
               end
      FakeRunner.new(Wrangle::MacOSHelper::Runner::Result.new(
                       stdout:, stderr: "", status: Status.new(true)
                     ))
    end
    vm = Wrangle::TartVM.new(name: "fixture-vm", runner_factory: factory)
    running = false

    error = assert_raises(Wrangle::DriverRefusal) { vm.verify! }
    assert_equal "scope_changed", error.code
  end

  def test_guest_helper_guards_every_read_and_refuses_execution
    guard = FakeGuard.new
    inner = FakeHelper.new
    helper = Wrangle::TartGuestHelper.new(vm_guard: guard, guest_app: "Finder", helper: inner)

    assert_equal "macos", helper.ping["platform"]
    windows = helper.windows(app: "Finder")
    assert_equal "w-1", windows.first["id"]
    assert_equal "tart-guest-v1:fixture-vm:1:2/guest-process", windows.first["process_instance"]
    process = "tart-guest-v1:fixture-vm:1:2/process"
    assert helper.enable_accessibility(pid: 42, process_instance: process)["verified"]
    assert_equal "one", helper.snapshot(
      pid: 42, process_instance: process, window_id: "w-1", bounds: {}, root_target: "root"
    )["snapshot_id"]
    assert_equal 4, guard.calls
    assert_equal [:ping, [:windows, "Finder", false], [:enable, 42, "process"],
                  [:snapshot, { pid: 42, process_instance: "process", window_id: "w-1", bounds: {},
                                root_target: "root", max_depth: 18 }]], inner.calls
    assert_raises(Wrangle::ScopeLost) { helper.windows(app: "Calculator") }
    ["another-vm/process", nil].each do |foreign_process|
      assert_raises(Wrangle::ScopeLost) do
        helper.enable_accessibility(pid: 42, process_instance: foreign_process)
      end
    end

    error = assert_raises(Wrangle::DriverRefusal) { helper.execute(operation: "PRESS") }
    assert_equal "read_only", error.code
    assert_equal "not_delivered", error.delivery
    assert_equal 6, guard.calls
  end

  def test_guest_helper_rejects_a_malformed_window_inventory
    guard = FakeGuard.new
    inner = FakeHelper.new
    inner.define_singleton_method(:windows) { |**| { "not" => "an array" } }
    helper = Wrangle::TartGuestHelper.new(vm_guard: guard, guest_app: "Finder", helper: inner)

    assert_raises(Wrangle::DriverError) { helper.windows(app: "Finder") }
  end

  def test_driver_exposes_reads_with_provenance_and_no_mutation_path
    guard = FakeGuard.new
    inner = FakeDriver.new
    driver = Wrangle::TartGuestDriver.new(
      vm_name: "fixture-vm", guest_app: "Finder", guard:, driver: inner
    )

    doctor = driver.doctor
    assert doctor["ready"]
    assert_equal "tart_guest", doctor["environment"]
    assert_equal "fixture-vm", doctor["vm"]
    assert_equal "Finder", doctor["guest_app"]
    assert doctor["read_only"]
    assert_equal "unavailable_read_only", doctor.dig("capabilities", "ax_dispatch")
    assert_equal [{ "app" => "Finder", "titles" => true }], driver.windows(app: "Finder", titles: true)
    assert_raises(Wrangle::ScopeLost) { driver.windows(app: "Calculator") }
    scope = driver.attach(window_id: "w-1", app: "Finder")
    assert_equal "Finder", scope.app
    assert_equal "tart-guest-v1:fixture-vm:1:2/guest-process", scope.process_instance
    assert_equal false, driver.observe(scope, skeleton: false)["skeleton"]
    assert_equal "one", driver.drill(scope, ref: "one", snapshot_id: "snapshot")["ref"]
    stale = Wrangle::MacOSDriver::Scope.new(**scope.to_h, process_instance: "another-vm/process")
    assert_raises(Wrangle::ScopeLost) { driver.observe(stale) }

    refusal = driver.execute(scope, operation: "PRESS")
    assert_equal "not_delivered", refusal["dispatch"]
    assert_equal "read_only", refusal["code"]
    driver.close
    assert inner.closed
  end

  def test_driver_requires_an_explicit_app_and_absolute_guest_helper
    guard = FakeGuard.new
    inner = FakeDriver.new

    assert_raises(ArgumentError) do
      Wrangle::TartGuestDriver.new(vm_name: "bad name", guest_app: "Finder", guard:, driver: inner)
    end
    assert_raises(ArgumentError) do
      Wrangle::TartGuestDriver.new(vm_name: "fixture-vm", guest_app: "", guard:, driver: inner)
    end
    assert_raises(ArgumentError) do
      Wrangle::TartGuestDriver.new(
        vm_name: "fixture-vm", guest_app: "Finder", guest_helper: "relative/helper", guard:, driver: inner
      )
    end
  end

  private

  def fixed_runner_factory(stdout:, successful: true)
    lambda do |_command|
      FakeRunner.new(Wrangle::MacOSHelper::Runner::Result.new(
                       stdout:, stderr: "", status: Status.new(successful)
                     ))
    end
  end

  def runner_factory(running: true, boot: "{ sec = 1790200000, usec = 123456 }", boots: nil)
    commands = []
    boot_values = Array(boots || [boot])
    factory = lambda do |command|
      commands << command
      stdout = if command[1] == "list"
                 JSON.generate([{ "Name" => "fixture-vm", "Running" => running }])
               else
                 boot_values.length > 1 ? boot_values.shift : boot_values.first
               end
      FakeRunner.new(Wrangle::MacOSHelper::Runner::Result.new(stdout:, stderr: "", status: Status.new(true)))
    end
    [factory, commands]
  end
end
