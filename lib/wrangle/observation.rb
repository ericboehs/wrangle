# frozen_string_literal: true

require "digest"
require "json"

module Wrangle
  # Turning an observation into something a decision can be checked against.
  module Observation
    # The fields that decide whether a page is "the same page" for the purpose of a decision.
    FINGERPRINTED = %w[url text actions scroll].freeze

    module_function

    def fingerprint(state)
      Digest::SHA256.hexdigest(JSON.generate(canonical(state.slice(*FINGERPRINTED))))
    end

    # Deterministic ordering, so an unchanged page always hashes the same way.
    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key.to_s, canonical(value[key])] }
      when Array then value.map { |element| canonical(element) }
      else value
      end
    end

    # Return the one observed candidate this action refers to, or refuse to act at all.
    #
    # This is the boundary that keeps model output from becoming instructions: a decision may only
    # name an action the page was just observed to offer, and it must match that candidate exactly.
    def require_observed(action, page)
      raise ArgumentError, "Actions require an observed page and action" unless action.is_a?(Hash) && page.is_a?(Hash)

      id = action["id"] || action[:id]
      candidates = page["actions"]
      raise ArgumentError, "Action is not bound to an observation" unless id.is_a?(String) && candidates.is_a?(Array)

      matches = candidates.select { |candidate| candidate.is_a?(Hash) && candidate["id"] == id }
      unless matches.one? && matches.first == stringify(action)
        raise ArgumentError, "Action is not an exact candidate from the observed page"
      end

      matches.first
    end

    def stringify(action)
      action.transform_keys(&:to_s)
    end
  end
end
