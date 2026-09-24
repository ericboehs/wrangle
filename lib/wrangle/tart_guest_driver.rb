# frozen_string_literal: true

require "json"

require_relative "errors"
require_relative "macos_driver"
require_relative "macos_helper"

module Wrangle
  # Binds a Tart VM name to one guest boot generation. Every guest-helper request verifies the VM
  # before and after transport, so a stop, reboot, replacement, or guest-agent reconnect loses scope
  # instead of silently attaching to a new desktop.
  class TartVM
    NAME = /\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\z/
    DEFAULT_TART = ENV.fetch("WRANGLE_TART", "tart")
    BOOT_COMMAND = %w[/usr/sbin/sysctl -n kern.boottime].freeze
    BOOT_PATTERN = /\bsec = (\d+), usec = (\d+)\b/
    TIMEOUT = 30

    attr_reader :name, :instance

    def initialize(name:, tart: DEFAULT_TART, runner_factory: nil, environment: ENV)
      raise ArgumentError, "A valid Tart VM name is required" unless name.is_a?(String) && name.match?(NAME)
      raise ArgumentError, "A Tart executable is required" if tart.to_s.empty? || tart.to_s.include?("\0")

      @name = name
      @tart = tart
      @environment = filtered_environment(environment)
      @runner_factory = runner_factory || method(:runner)
      @instance = capture_instance
    end

    def around
      verify!
      result = yield
      verify!
      result
    end

    def verify!
      actual = capture_instance
      return true if actual == instance

      raise DriverRefusal.new(
        "scope_changed", "The scoped Tart guest restarted or was replaced",
        delivery: "not_delivered", retry_disposition: "unsafe"
      )
    rescue DriverRefusal
      raise
    rescue DriverError
      raise DriverRefusal.new(
        "scope_changed", "The scoped Tart guest is no longer available",
        delivery: "not_delivered", retry_disposition: "unsafe"
      )
    end

    private

    def capture_instance
      selected = inventory.select { |record| record["Name"] == name }
      unless selected.one? && selected.first["Running"] == true
        raise DriverUnavailable, "The exact Tart guest is not running"
      end

      boot = run(@tart, "exec", name, *BOOT_COMMAND)
      match = BOOT_PATTERN.match(boot)
      raise DriverError, "The Tart guest returned no stable boot identity" unless match

      "tart-guest-v1:#{name}:#{match[1]}:#{match[2]}"
    end

    def inventory
      parsed = JSON.parse(run(@tart, "list", "--format", "json"))
      valid = parsed.is_a?(Array) && parsed.all? { |record| record.is_a?(Hash) }
      raise DriverError, "Tart returned an invalid VM inventory" unless valid

      parsed
    rescue JSON::ParserError
      raise DriverError, "Tart returned invalid VM inventory JSON"
    end

    def run(*command)
      result = @runner_factory.call(command).call
      raise DriverUnavailable, "Tart guest transport is unavailable" unless result.status.success?

      result.stdout
    end

    def runner(command)
      MacOSHelper::Runner.new(command:, environment: @environment, timeout: TIMEOUT)
    end

    def filtered_environment(source)
      MacOSHelper::SAFE_ENV.each_with_object({}) { |key, kept| kept[key] = source[key] if source.key?(key) }
    end
  end

  # Presents the normal MacOSHelper contract over Tart's argument-only guest-agent transport.
  class TartGuestHelper
    def initialize(vm_guard:, guest_app:, helper:)
      @vm_guard = vm_guard
      @guest_app = guest_app
      @helper = helper
    end

    def ping = guarded { @helper.ping }
    def displays = guarded { @helper.displays }

    def windows(app:, titles: false)
      validate_app!(app)
      guarded do
        windows = @helper.windows(app:, titles:)
        unless windows.is_a?(Array) && windows.all? { |window| window.is_a?(Hash) }
          raise DriverError, "The guest helper returned an invalid window inventory"
        end

        windows.map do |window|
          process = window["process_instance"]
          process.is_a?(String) ? window.merge("process_instance" => scoped_process(process)) : window
        end
      end
    end

    def enable_accessibility(pid:, process_instance:)
      guarded { @helper.enable_accessibility(pid:, process_instance: guest_process(process_instance)) }
    end

    def snapshot(pid:, process_instance:, window_id:, bounds:, root_target: nil, max_depth: 18)
      guarded do
        @helper.snapshot(
          pid:, process_instance: guest_process(process_instance), window_id:, bounds:, root_target:, max_depth:
        )
      end
    end

    def execute(*)
      raise DriverRefusal.new(
        "read_only", "The Tart guest prototype does not dispatch actions",
        delivery: "not_delivered", retry_disposition: "unsafe"
      )
    end

    private

    def guarded(&) = @vm_guard.around(&)

    def validate_app!(app)
      return if app.to_s.casecmp?(@guest_app)

      raise ScopeLost, "The Tart guest driver cannot leave its explicit application scope"
    end

    def scoped_process(process_instance) = "#{@vm_guard.instance}/#{process_instance}"

    def guest_process(process_instance)
      prefix = "#{@vm_guard.instance}/"
      unless process_instance.is_a?(String) && process_instance.start_with?(prefix)
        raise ScopeLost, "The process does not belong to the scoped Tart guest"
      end

      process_instance.delete_prefix(prefix)
    end
  end

  # Read-only exact-window driver for one explicitly named Tart VM and one explicitly named guest
  # application. It deliberately exposes no mutation path and never falls back to the host Tart view.
  class TartGuestDriver
    DEFAULT_HELPER = ENV.fetch(
      "WRANGLE_TART_GUEST_HELPER",
      "/Users/admin/Applications/Wrangle Helper.app/Contents/MacOS/wrangle-macos-helper"
    )

    attr_reader :vm_name, :vm_instance, :guest_app

    def initialize(vm_name:, guest_app:, tart: TartVM::DEFAULT_TART, guest_helper: DEFAULT_HELPER,
                   guard: nil, helper: nil, driver: nil)
      validate_helper!(guest_helper)
      unless vm_name.is_a?(String) && vm_name.match?(TartVM::NAME)
        raise ArgumentError, "A valid Tart VM name is required"
      end
      raise ArgumentError, "An explicit Tart guest application is required" if guest_app.to_s.strip.empty?

      @guard = guard || TartVM.new(name: vm_name, tart:)
      guest = helper || MacOSHelper.new(command: [tart, "exec", vm_name, guest_helper])
      guarded = TartGuestHelper.new(vm_guard: @guard, guest_app:, helper: guest)
      @driver = driver || MacOSDriver.new(helper: guarded, observation_driver: "tart_guest", read_only: true)
      @vm_name = vm_name
      @vm_instance = @guard.instance
      @guest_app = guest_app
    end

    def doctor
      result = @driver.doctor
      capabilities = Hash(result["capabilities"]).merge("ax_dispatch" => "unavailable_read_only")
      result.merge(
        "environment" => "tart_guest", "vm" => vm_name, "guest_app" => guest_app,
        "read_only" => true, "capabilities" => capabilities
      )
    end

    def windows(app:, titles: false)
      validate_app!(app)
      @driver.windows(app:, titles:)
    end

    def displays = @driver.displays

    def attach(window_id:, app:)
      validate_app!(app)
      @driver.attach(window_id:, app:).tap { |scope| validate_scope!(scope) }
    end

    def observe(scope, skeleton: true)
      validate_scope!(scope)
      @driver.observe(scope, skeleton:)
    end

    def drill(scope, ref:, snapshot_id:)
      validate_scope!(scope)
      @driver.drill(scope, ref:, snapshot_id:)
    end

    def execute(*)
      {
        "dispatch" => "not_delivered", "code" => "read_only",
        "message" => "The Tart guest prototype does not dispatch actions", "retry_safe" => false
      }
    end

    def close = @driver.close

    private

    def validate_scope!(scope)
      return if scope.process_instance.to_s.start_with?("#{vm_instance}/")

      raise ScopeLost, "The Tart guest scope is stale or belongs to another driver"
    end

    def validate_helper!(path)
      valid = path.is_a?(String) && path.start_with?("/") && !path.include?("\0") && !path.include?("\n")
      raise ArgumentError, "An absolute Tart guest helper path is required" unless valid
    end

    def validate_app!(app)
      return if app.to_s.casecmp?(guest_app)

      raise ScopeLost, "The Tart guest driver cannot leave its explicit application scope"
    end
  end
end
