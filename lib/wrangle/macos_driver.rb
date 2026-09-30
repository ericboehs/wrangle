# frozen_string_literal: true

require "securerandom"
require "time"

require_relative "desktop_observation"
require_relative "errors"
require_relative "macos_helper"

module Wrangle
  # Owns exact-window macOS observation and dispatch through the shipped native helper.
  #
  # One selected CoreGraphics window, process generation, bounds, and AX target remain authoritative.
  # Snapshot refs are scope-bound capabilities; every dispatch resolves a fresh target and verifies
  # its signature before acting. Wrangle owns policy, proposals, at-most-once dispatch, and receipts.
  class MacOSDriver
    ELECTRON_BUNDLES = %w[com.tinyspeck.slackmacgap com.microsoft.teams2].freeze
    NATIVE_SNAPSHOT_LIMIT = 8

    Scope = Data.define(:id, :root, :app, :bundle_id, :pid, :process_instance, :bounds, :display_id,
                        :attached_at)

    attr_reader :helper

    def initialize(helper: MacOSHelper.new, observation_driver: "macos", read_only: false)
      @helper = helper
      @observation_driver = observation_driver
      @read_only = read_only
      @prepared_processes = {}
      @native_snapshots = {}
      @native_targets = {}
    end

    def close
      @prepared_processes.clear
      @native_snapshots.clear
      @native_targets.clear
    end

    def doctor
      native = @helper.ping
      native_displays = @helper.displays
      {
        "ready" => native["accessibility"] == true && native["session_locked"] != true,
        "platform" => native["platform"], "session_locked" => native["session_locked"] == true,
        "driver" => "macos_native",
        "capabilities" => {
          "window_inventory" => "macos_native", "display_inventory" => "macos_native",
          "electron_accessibility" => "macos_native", "ax_snapshot" => "macos_native_exact_window",
          "ax_dispatch" => "macos_native_exact_window"
        },
        "displays" => native_displays.length
      }
    rescue DriverError => e
      { "ready" => false, "error" => e.message, "class" => e.class.name.split("::").last }
    end

    def windows(app:, titles: false) = @helper.windows(app:, titles:)
    def displays = @helper.displays
    def frontmost(titles: false) = @helper.frontmost(titles:)

    def attach(window_id:, app:)
      matches = windows(app:).select { |window| window["id"] == window_id }
      raise ScopeLost, "Window #{window_id.inspect} is not a visible #{app} window" if matches.empty?
      raise ScopeLost, "Window #{window_id.inspect} is ambiguous" unless matches.one?

      window = matches.first
      validate_window!(window)
      Scope.new(id: SecureRandom.uuid, root: window["id"], app: window["app_name"],
                bundle_id: window["bundle_id"], pid: window["pid"],
                process_instance: window["process_instance"], bounds: window["bounds"],
                display_id: display_for(window["bounds"]), attached_at: Time.now.utc.iso8601)
    end

    def prepare(scope)
      return { "changed" => false, "verified" => true, "reason" => "not_electron" } unless
        ELECTRON_BUNDLES.include?(scope.bundle_id)

      cached = @prepared_processes[scope.process_instance]
      return cached.merge("changed" => false, "cached" => true) if cached

      result = @helper.enable_accessibility(pid: scope.pid, process_instance: scope.process_instance)
      @prepared_processes[scope.process_instance] = result
    end

    def observe(scope, skeleton: true)
      window = current_window(scope)
      setup = prepare(scope)
      snapshot = native_snapshot(scope, window, max_depth: skeleton ? 18 : 24)
      observation(scope, snapshot, window, setup)
    end

    def drill(scope, ref:, snapshot_id:)
      window = current_window(scope)
      setup = prepare(scope)
      entry = @native_snapshots[snapshot_id]
      target = entry&.fetch("targets", {})&.[](ref)
      unless entry && entry["scope_id"] == scope.id && target
        raise DriverRefusal.new("STALE_REF", "Native AX drill ref is stale", delivery: "not_delivered")
      end

      snapshot = native_snapshot(scope, window, root_target: target, max_depth: 20)
      observation(scope, snapshot, window, setup)
    end

    def execute(scope, operation:, ref: nil, text: nil)
      window = current_window(scope)
      entry = @native_targets[ref]
      unless entry && entry["scope_id"] == scope.id
        raise DriverRefusal.new("STALE_REF", "Native AX action ref is stale", delivery: "not_delivered")
      end

      @helper.execute(
        pid: scope.pid, process_instance: scope.process_instance, window_id: scope.root,
        bounds: window.fetch("bounds"), target: entry.fetch("target"), operation:, text:
      )
    rescue DriverRefusal => e
      dispatch = if e.delivery_unknown?
                   "delivery_unknown"
                 elsif e.delivery == "not_delivered"
                   "not_delivered"
                 else
                   "refused"
                 end
      { "dispatch" => dispatch, "code" => e.code, "message" => e.message,
        "retry_safe" => e.safe_to_retry? }
    end

    private

    def observation(scope, snapshot, window, setup)
      DesktopObservation.new(
        scope:, snapshot:, window:, driver: @observation_driver, read_only: @read_only
      ).state.tap do |state|
        state["observation_setup"] = setup.merge("snapshot_source" => snapshot.fetch("source"))
      end
    end

    def native_snapshot(scope, window, max_depth:, root_target: nil)
      raw = @helper.snapshot(
        pid: scope.pid, process_instance: scope.process_instance, window_id: scope.root,
        bounds: window.fetch("bounds"), root_target:, max_depth:
      )
      snapshot_id = raw["snapshot_id"]
      targets = raw.delete("targets")
      unless snapshot_id.is_a?(String) && raw["tree"].is_a?(Hash) && targets.is_a?(Hash)
        raise DriverError, "Native AX helper returned an incomplete snapshot"
      end

      @native_snapshots[snapshot_id] = { "scope_id" => scope.id, "targets" => targets }
      targets.each do |reference, target|
        @native_targets[reference] = { "scope_id" => scope.id, "target" => target }
      end
      evict_native_snapshots
      raw.merge("source" => "macos_helper_native",
                "provenance" => Array(raw["provenance"]) | %w[ax macos_helper_native])
    end

    def evict_native_snapshots
      while @native_snapshots.length > NATIVE_SNAPSHOT_LIMIT
        _, removed = @native_snapshots.shift
        removed.fetch("targets").each_key { |reference| @native_targets.delete(reference) }
      end
    end

    def current_window(scope)
      matches = windows(app: scope.app).select { |window| window["id"] == scope.root }
      unless matches.one? && matches.first["process_instance"] == scope.process_instance &&
             matches.first["bundle_id"] == scope.bundle_id
        raise ScopeLost, "The attached macOS window or application process changed"
      end

      matches.first
    end

    def validate_window!(window)
      required = %w[id app_name bundle_id pid process_instance bounds]
      return if required.all? { |key| window.key?(key) } && window["pid"].is_a?(Integer) &&
                window["process_instance"].is_a?(String) && window["bounds"].is_a?(Hash)

      raise DriverError, "macOS returned an incomplete window identity"
    end

    def display_for(bounds)
      ranked = displays.filter_map do |display|
        overlap = intersection(bounds, display["bounds"])
        [overlap, display["id"]] if overlap.positive?
      end
      ranked.max_by(&:first)&.last
    end

    def intersection(one, two)
      left = [one["x"], two["x"]].max
      top = [one["y"], two["y"]].max
      right = [one["x"] + one["width"], two["x"] + two["width"]].min
      bottom = [one["y"] + one["height"], two["y"] + two["height"]].min
      [right - left, 0].max * [bottom - top, 0].max
    end
  end
end
