# frozen_string_literal: true

require "securerandom"

require_relative "desktop_observation"
require_relative "errors"

module Wrangle
  # Validates and binds one typed action to one semantic desktop revision.
  class DesktopProposal
    TTL = 300
    MAX_TEXT = 2000

    def self.build(scope:, observation:, request:, policy:, created_at:)
      index = request["ref"]
      candidate = candidate(observation, index)
      operation = request["operation"] || infer_operation(candidate)
      unless candidate["operations"].include?(operation) && operation != "DRILL"
        raise ArgumentError, "#{operation.inspect} was not offered for action ##{index.inspect}"
      end
      unless DesktopObservation.action_unambiguous?(observation["candidates"], candidate, operation)
        raise ArgumentError, "#{operation.inspect} for action ##{index.inspect} matches multiple visible candidates"
      end

      validate_text!(operation, request["text"])
      assessment = policy.assess(scope:, candidate:, operation:)
      raise PolicyDenied, assessment.reason unless assessment.permitted

      {
        "id" => SecureRandom.hex(12), "scope_id" => scope.id, "revision" => observation["revision"],
        "candidate" => candidate, "number" => index, "operation" => operation, "text" => request["text"],
        "policy" => assessment.to_h, "created_at" => created_at
      }
    end

    def self.compact(proposal)
      text = proposal["text"]
      {
        "schema" => "wrangle.proposal.v1", "proposal_id" => proposal["id"],
        "scope_id" => proposal["scope_id"], "revision" => proposal["revision"],
        "action" => { "ref" => proposal["number"], "operation" => proposal["operation"],
                      "role" => proposal.dig("candidate", "role"),
                      "label" => proposal.dig("candidate", "label"),
                      "text" => text && { "source" => "explicit", "characters" => text.length } }.compact,
        "policy" => proposal["policy"]
      }
    end

    def self.candidate(observation, index)
      candidates = observation["candidates"]
      unless index.is_a?(Integer) && index.positive? && index <= candidates.length
        raise ArgumentError, "No action ##{index.inspect} in the current desktop observation"
      end

      candidates[index - 1]
    end

    def self.infer_operation(candidate)
      actions = candidate["operations"] - ["DRILL"]
      raise ArgumentError, "Specify one of #{actions.join(", ")}" unless actions.one?

      actions.first
    end
    private_class_method :infer_operation

    def self.validate_text!(operation, text)
      raise ArgumentError, "Text is valid only for SET_TEXT" if operation != "SET_TEXT" && !text.nil?
      return unless operation == "SET_TEXT"
      return if text.is_a?(String) && !text.empty? && text.length <= MAX_TEXT && !text.include?("\0")

      raise ArgumentError, "SET_TEXT requires an exact non-empty string of at most #{MAX_TEXT} characters"
    end
    private_class_method :validate_text!
  end
end
