# frozen_string_literal: true

require "securerandom"

require_relative "desktop_session_server"
require_relative "event_log"
require_relative "macos_driver"
require_relative "provider_factory"
require_relative "scope_registry"

module Wrangle
  # Selects one exact application window and owns one bounded AX → choice → policy → action loop.
  # The outer agent supplies a natural goal once; low-level refs and proposals never cross this API.
  class DesktopTask
    DEFAULT_STEPS = 8
    MAX_STEPS = 8

    def initialize(driver: MacOSDriver.new, provider: nil, registry: nil, log: nil)
      @driver = driver
      @provider = provider
      @registry = registry
      @log = log
      @driver_owned = true
    end

    def run(app:, goal:, literals: {}, steps: DEFAULT_STEPS, min_confidence: 0.5,
            concurrency: "exclusive", provider_options: {})
      app = app.to_s.strip
      goal = goal.to_s.strip
      raise ArgumentError, "A macOS application name is required" if app.empty?
      raise ArgumentError, "A desktop task goal is required" if goal.empty?

      budget = Integer(steps)
      raise ArgumentError, "Desktop task budget must be between 1 and #{MAX_STEPS}" unless
        budget.between?(1, MAX_STEPS)

      provider = @provider || ProviderFactory.build(provider_options)
      window = select_window(app)
      scope = @driver.attach(window_id: window.fetch("id"), app: window.fetch("app_name"))
      log = @log || EventLog.new(session: "task-#{SecureRandom.hex(6)}")
      server = DesktopSessionServer.new(
        nil, { "concurrency" => concurrency }, driver: @driver, scope:, registry: @registry,
                                               log:, provider:
      )
      @driver_owned = false
      server.run_task(
        "goal" => goal, "literals" => literals, "steps" => budget,
        "min_confidence" => min_confidence
      )
    ensure
      @driver.close if @driver_owned
    end

    private

    def select_window(app)
      windows = @driver.windows(app:, titles: true)
      raise ScopeLost, "No visible #{app} window is available" if windows.empty?
      return windows.first if windows.one?

      focused = windows.select { |window| window["focused"] == true }
      return focused.first if focused.one?

      raise ScopeLost, "More than one #{app} window is visible and none is uniquely focused"
    end
  end
end
