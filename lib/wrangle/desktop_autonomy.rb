# frozen_string_literal: true

require_relative "desktop_decider"
require_relative "errors"

module Wrangle
  # Bounded read-only decision phase; mutation remains DesktopSessionServer's responsibility.
  class DesktopAutonomy
    Assessment = Data.define(:choice, :observation, :paused)
    DRILL_BUDGET = 8

    def initialize(provider)
      @provider = provider
    end

    attr_reader :provider

    def assess(goal:, literals:, observation:, history:, min_confidence:)
      decider = DesktopDecider.new(goal:, literals:, provider:)
      choice = nil
      DRILL_BUDGET.times do
        choice = decider.decide(observation, history:)
        break unless choice.operation == "DRILL"

        observation = yield(choice.number)
      end
      raise PartialObservation, "Provider exceeded the progressive DRILL budget" if choice.operation == "DRILL"

      floor = Float(min_confidence)
      raise ArgumentError, "Minimum confidence must be between zero and one" unless floor.between?(0, 1)

      paused = "low_confidence" if choice.confidence < floor
      Assessment.new(choice:, observation:, paused:)
    end

    def evidence(goal:, observation:, history:, limit: 3)
      DesktopDecider.new(goal:, literals: {}, provider:).select_evidence(observation, history:, limit:)
    end

    def compact(assessment, proposal: nil)
      choice = assessment.choice
      text = choice.text
      {
        "schema" => "wrangle.decision.v1", "operation" => choice.operation,
        "confidence" => choice.confidence, "latency_ms" => choice.latency_ms,
        "provider" => choice.provider, "model" => choice.model, "terminal" => choice.terminal?,
        "action" => choice.number && { "ref" => choice.number, "operation" => choice.operation,
                                       "text" => text && { "source" => choice.text_source,
                                                           "characters" => text.length } },
        "proposal" => proposal, "paused" => assessment.paused
      }.compact
    end

    def status
      capabilities = provider.capabilities
      { "name" => capabilities.provider, "model" => capabilities.model,
        "runtime" => capabilities.runtime, "transport" => capabilities.transport,
        "max_choices" => capabilities.max_choices, "mutation_qualified" => capabilities.mutation_qualified }
    end
  end
end
