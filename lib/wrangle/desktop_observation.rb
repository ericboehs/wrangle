# frozen_string_literal: true

require "digest"
require "json"

require_relative "errors"
require_relative "observation"

module Wrangle
  # Normalizes a driver's hierarchical AX snapshot without throwing away its progressive structure.
  class DesktopObservation
    TEXT_ROLES = %w[textfield textarea searchfield combobox].freeze
    TOGGLE_ROLES = %w[checkbox switch radiobutton].freeze
    WINDOW_CONTROL = /\A(?:close|close window|close all|quit(?: .*)?|minimize|zoom|full ?screen)\z/i

    attr_reader :state

    class << self
      # Provider and result evidence includes non-actionable text as well as controls. Returning only
      # candidates made read-only tasks impossible to prove and allowed DONE without seeing the fact.
      def evidence_items(observation)
        items = []
        seen = {}
        collect_evidence(observation["tree"], items, seen) if observation["tree"].is_a?(Hash)
        Array(observation["candidates"]).each do |candidate|
          add_evidence(items, seen, candidate.slice("role", "label", "value", "states"))
        end
        items
      end

      private

      def collect_evidence(node, items, seen)
        visible = { "role" => node["role"].to_s.downcase, "label" => node["name"].to_s,
                    "value" => scalar_value(node["value"]), "states" => Array(node["states"]).map(&:to_s) }
        add_evidence(items, seen, visible) unless visible["role"] == "window"
        Array(node["children"]).each do |child|
          collect_evidence(child, items, seen) if child.is_a?(Hash)
        end
      end

      def add_evidence(items, seen, visible)
        visible = visible.compact
        label = visible["label"].to_s
        value = visible["value"]
        return if label.empty? && (value.nil? || value.to_s.empty?)
        return if seen[visible]

        seen[visible] = true
        items << visible
      end

      def scalar_value(value)
        value if value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
      end
    end

    def initialize(scope:, snapshot:, window:)
      @scope = scope
      @snapshot = snapshot
      @window = window
      validate!
      @state = build
    end

    def revision = @state.fetch("revision")
    def candidates = @state.fetch("candidates")

    private

    def validate!
      unless @snapshot.is_a?(Hash) && @snapshot["snapshot_id"].is_a?(String) && @snapshot["tree"].is_a?(Hash)
        raise DriverError, "Desktop observation requires a complete driver snapshot"
      end
      unless @window.is_a?(Hash) && @window["id"] == @scope.root &&
             @window["process_instance"] == @scope.process_instance
        raise ScopeLost, "The observed window is no longer the attached root surface"
      end

      observed_id = @snapshot.dig("window", "id")
      raise ScopeLost, "The AX snapshot belongs to another window" if observed_id && observed_id != @scope.root
    end

    def build
      candidates = []
      walk(@snapshot["tree"], candidates)
      body = {
        "schema" => "wrangle.observation.v1", "driver" => "macos",
        "scope" => { "id" => @scope.id, "root" => @scope.root, "app" => @scope.app,
                     "pid" => @scope.pid, "process_instance" => @scope.process_instance },
        "window" => @window.slice("id", "bounds", "focused", "visible"),
        "snapshot_id" => @snapshot["snapshot_id"], "complete" => @snapshot.fetch("complete", true),
        "tree" => @snapshot["tree"], "candidates" => candidates,
        "coverage" => coverage(candidates)
      }
      body["revision"] = fingerprint(body)
      body
    end

    def walk(node, candidates)
      candidate = candidate(node)
      candidates << candidate if candidate
      Array(node["children"]).each { |child| walk(child, candidates) if child.is_a?(Hash) }
    end

    def candidate(node)
      ref = node["ref_id"]
      return nil unless ref.is_a?(String)

      role = node["role"].to_s.downcase
      operations = operations(role, node)
      operations &= ["DRILL"] if Array(node["states"]).map(&:to_s).include?("disabled")
      operations -= ["PRESS"] if window_control?(role, node)
      return nil if operations.empty?

      {
        "ref" => ref, "role" => role, "subrole" => node["subrole"], "label" => node["name"].to_s,
        "value" => scalar(node["value"]), "states" => Array(node["states"]).map(&:to_s),
        "operations" => operations, "children_count" => node["children_count"],
        "target_key" => node["target_key"]
      }.compact
    end

    def window_control?(_role, node)
      subrole = node["subrole"].to_s.delete_prefix("AX").downcase
      %w[closebutton minimizebutton zoombutton fullscreenbutton].include?(subrole) ||
        node["name"].to_s.match?(WINDOW_CONTROL)
    end

    def operations(role, node)
      observed = node["operations"]
      return native_operations(observed, node) if observed.is_a?(Array)

      offered = []
      offered << "DRILL" if node["children_count"].to_i.positive?
      offered.push("SET_TEXT", "CLEAR") if TEXT_ROLES.include?(role)
      offered << "TOGGLE" if TOGGLE_ROLES.include?(role)
      offered << "PRESS" unless role.empty? || role == "window"
      offered
    end

    def native_operations(observed, node)
      allowed = %w[PRESS SET_TEXT CLEAR TOGGLE EXPAND COLLAPSE]
      offered = observed.map(&:to_s) & allowed
      offered.unshift("DRILL") if node["children_count"].to_i.positive?
      offered.uniq
    end

    def scalar(value)
      value if value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
    end

    def coverage(candidates)
      truncated = @snapshot["complete"] == false || truncated?(@snapshot["tree"])
      provenance = Array(@snapshot["provenance"])
      provenance = ["ax"] if provenance.empty?
      { "provenance" => provenance, "truncated" => truncated,
        "candidate_count" => candidates.length, "ocr" => "not_used" }
    end

    def truncated?(node)
      node["children_count"].to_i.positive? || Array(node["children"]).any? do |child|
        child.is_a?(Hash) && truncated?(child)
      end
    end

    def fingerprint(body)
      # Non-actionable AX text can be intrinsically volatile (Finder's free-space status changes
      # when the proposal log is written). Revisions bind scope, coverage, and every offered target,
      # while the full tree remains available for inspection and progressive traversal.
      semantic = without_refs(body.except("snapshot_id", "tree"))
      Digest::SHA256.hexdigest(JSON.generate(Observation.canonical(semantic)))[0, 24]
    end

    def without_refs(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), stripped|
          stripped[key] = without_refs(child) unless %w[ref ref_id].include?(key)
        end
      when Array then value.map { |child| without_refs(child) }
      else value
      end
    end
  end
end
