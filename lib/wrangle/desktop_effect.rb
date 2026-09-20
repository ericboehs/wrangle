# frozen_string_literal: true

module Wrangle
  # Verifies the intended target-specific postcondition after a delivered native action. A changed
  # desktop revision is never proof by itself: unrelated animation, status text, or another control
  # may have changed at the same time. When the intended target cannot be identified or its required
  # state is outside partial coverage, the effect remains unverified.
  class DesktopEffect
    OPERATIONS = %w[PRESS SET_TEXT CLEAR TOGGLE EXPAND COLLAPSE].freeze
    TOGGLE_ROLES = %w[checkbox switch radiobutton].freeze

    class << self
      def verify(proposal, before, after)
        return "unverified" unless before.is_a?(Hash) && after.is_a?(Hash)

        operation = proposal["operation"].to_s
        candidate = proposal["candidate"]
        return "unverified" unless OPERATIONS.include?(operation) && candidate.is_a?(Hash)

        match, target = find_target(candidate, after)
        return missing_target_effect(operation, before, after) if match == :missing
        return "unverified" unless match == :found

        case operation
        when "PRESS" then verify_press(candidate, target, before, after)
        when "SET_TEXT" then verify_set_text(candidate, target, proposal["text"], before, after)
        when "CLEAR" then verify_clear(candidate, target, before, after)
        when "TOGGLE" then verify_toggle(candidate, target, before, after)
        when "EXPAND", "COLLAPSE" then verify_expansion(operation, candidate, target, before, after)
        end
      end

      private

      def find_target(candidate, observation)
        elements = observation_elements(observation)
        target_key = candidate["target_key"].to_s
        unless target_key.empty?
          keyed = elements.select do |element|
            element["target_key"] == target_key && element["role"].to_s == candidate["role"].to_s
          end
          return [:found, keyed.first] if keyed.one?
          return [:ambiguous, nil] if keyed.length > 1
        end

        visible = elements.select { |element| same_visible_identity?(candidate, element) }
        return [:found, visible.first] if visible.one?
        return [:missing, nil] if visible.empty?

        [:ambiguous, nil]
      end

      def observation_elements(observation)
        tree = observation["tree"]
        return Array(observation["candidates"]) unless tree.is_a?(Hash)

        elements = []
        stack = [tree]
        until stack.empty?
          node = stack.pop
          elements << normalize_tree_node(node)
          stack.concat(Array(node["children"]).select { |child| child.is_a?(Hash) })
        end
        elements
      end

      def normalize_tree_node(node)
        {
          "role" => node["role"], "subrole" => node["subrole"], "label" => node["name"],
          "value" => node["value"], "states" => node["states"], "operations" => node["operations"],
          "children_count" => node["children_count"], "target_key" => node["target_key"]
        }
      end

      def same_visible_identity?(before, after)
        before["role"].to_s == after["role"].to_s &&
          before["subrole"].to_s == after["subrole"].to_s &&
          before["label"].to_s == after["label"].to_s
      end

      def missing_target_effect(operation, before, after)
        return "unverified" unless operation == "PRESS" && complete?(after)

        changed_revision?(before, after) ? "verified" : "unverified"
      end

      def verify_press(candidate, target, before, after)
        return "unchanged" if press_signature(candidate) == press_signature(target)

        changed_revision?(before, after) ? "verified" : "unverified"
      end

      def press_signature(candidate)
        {
          "label" => candidate["label"].to_s, "value" => candidate["value"],
          "states" => Array(candidate["states"]).map(&:to_s).reject { |state| state == "focused" }.uniq.sort,
          "operations" => Array(candidate["operations"]).map(&:to_s).reject { |op| op == "DRILL" }.uniq.sort,
          "children_count" => candidate["children_count"]
        }
      end

      def verify_set_text(candidate, target, text, before, after)
        return "unverified" unless text.is_a?(String) && same_visible_identity?(candidate, target)
        return "unchanged" unless target["value"] == text
        return "unchanged" if candidate["value"] == text

        changed_revision?(before, after) ? "verified" : "unverified"
      end

      def verify_clear(candidate, target, before, after)
        return "unverified" unless same_visible_identity?(candidate, target) && target["value"].is_a?(String)
        return "unchanged" unless target["value"].strip.empty?
        return "unchanged" if candidate["value"].is_a?(String) && candidate["value"].strip.empty?

        changed_revision?(before, after) ? "verified" : "unverified"
      end

      def verify_toggle(candidate, target, before, after)
        return "unverified" unless same_visible_identity?(candidate, target)

        previous = toggle_value(candidate)
        current = toggle_value(target)
        return "unverified" if previous.nil? || current.nil?
        return "unchanged" if previous == current

        changed_revision?(before, after) ? "verified" : "unverified"
      end

      def toggle_value(candidate)
        return unless TOGGLE_ROLES.include?(candidate["role"].to_s)

        scalar = candidate["value"]
        return scalar if [true, false].include?(scalar)
        return scalar == 1 if [0, 1].include?(scalar)

        states = Array(candidate["states"]).map(&:to_s)
        states.include?("checked") || states.include?("selected")
      end

      def verify_expansion(operation, candidate, target, before, after)
        return "unverified" unless same_visible_identity?(candidate, target) &&
                                   candidate.key?("states") && target.key?("states")

        previous = Array(candidate["states"]).map(&:to_s).include?("expanded")
        current = Array(target["states"]).map(&:to_s).include?("expanded")
        expected_previous = operation == "COLLAPSE"
        return "unverified" unless previous == expected_previous
        return "unchanged" if previous == current

        changed_revision?(before, after) ? "verified" : "unverified"
      end

      def complete?(observation)
        observation["complete"] == true && observation.dig("coverage", "truncated") != true
      end

      def changed_revision?(before, after)
        previous = before["revision"]
        current = after["revision"]
        previous.is_a?(String) && current.is_a?(String) && !previous.empty? && previous != current
      end
    end
  end
end
