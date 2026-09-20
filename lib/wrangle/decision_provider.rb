# frozen_string_literal: true

require "json"

require_relative "errors"

module Wrangle
  # Vendor-neutral, choice-only provider boundary used by desktop autonomy.
  class DecisionProvider
    PROTOCOL = "wrangle.choice.v1"
    Decision = Data.define(:choice, :confidence, :probabilities, :latency_ms)
    Capabilities = Data.define(:protocol, :max_choices, :confidence, :hierarchical, :mutation_qualified,
                               :provider, :model, :runtime, :transport)

    def initialize(transport:, capabilities:)
      @transport = transport
      @capabilities = capabilities.is_a?(Capabilities) ? capabilities : Capabilities.new(**capabilities)
      validate_capabilities!
    end

    attr_reader :capabilities

    def choose(state:, name:, criteria:, instructions:)
      raise ArgumentError, "A provider question needs at least two choices" unless criteria.is_a?(Hash) &&
                                                                                   criteria.length >= 2
      if criteria.length > capabilities.max_choices
        raise ProviderError, "Provider choice limit exceeded; use hierarchical selection"
      end

      started = monotonic
      response = call_transport(
        "protocol" => PROTOCOL, "state" => state,
        "question" => { "name" => name, "criteria" => criteria, "instructions" => instructions }
      )
      answer = response.is_a?(Hash) ? response["answer"] : nil
      validate_answer!(answer, criteria.keys)
      Decision.new(choice: answer["choice"], confidence: answer["confidence"],
                   probabilities: answer["probabilities"], latency_ms: elapsed_ms(started))
    end

    def mutation_qualified? = capabilities.mutation_qualified

    private

    def call_transport(request)
      @transport.call(request)
    rescue ProviderError
      raise
    rescue StandardError => e
      raise ProviderError, "Decision provider failed: #{e.class}"
    end

    def validate_capabilities!
      valid = capabilities.protocol == PROTOCOL && capabilities.max_choices.is_a?(Integer) &&
              capabilities.max_choices >= 2 && capabilities.hierarchical == true &&
              [true, false].include?(capabilities.confidence) &&
              [true, false].include?(capabilities.mutation_qualified)
      raise ConfigurationError, "Decision provider capabilities are incompatible" unless valid
    end

    def validate_answer!(answer, offered)
      probabilities = answer.is_a?(Hash) ? answer["probabilities"] : nil
      valid = probabilities.is_a?(Hash) && offered.include?(answer["choice"]) &&
              probabilities.keys.sort == offered.sort && distribution?(probabilities, answer["confidence"]) &&
              probabilities[answer["choice"]] >= probabilities.values.max - 1e-6
      raise ProviderError, "Decision provider returned an invalid choice distribution" unless valid
    end

    def distribution?(probabilities, confidence)
      numbers = probabilities.values + [confidence]
      numbers.all? { |number| number.is_a?(Numeric) && number.finite? && number.between?(0, 1) } &&
        (probabilities.values.sum - 1).abs < 0.02
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def elapsed_ms(started) = ((monotonic - started) * 1000).round(1)
  end

  # Adapts the existing Jev-compatible HTTP client without coupling the engine to TypeSafe.
  class JevChoiceTransport
    def initialize(client)
      @client = client
    end

    def call(request)
      question = request.fetch("question")
      response = @client.ask(
        state: request.fetch("state"),
        questions: {
          question.fetch("name") => {
            "type" => "choice", "criteria" => question.fetch("criteria"),
            "instructions" => question.fetch("instructions")
          }
        }
      )
      { "answer" => response.fetch("answers").fetch(question.fetch("name")) }
    end
  end

  # Deterministic transport for qualification, replay benchmarks, and offline tests.
  class ReplayChoiceTransport
    def initialize(records)
      @records = records.map(&:dup)
    end

    def self.load(path)
      records = File.foreach(path).reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
      records.map! do |record|
        next record unless record["schema"] == "wrangle.provider-case.v1"

        { "name" => record.dig("request", "name"), "answer" => record.fetch("answer") }
      end
      new(records)
    end

    def call(request)
      record = @records.shift
      raise ProviderError, "Replay trace ended before the decision" unless record
      unless record["name"] == request.dig("question", "name")
        raise ProviderError, "Replay trace question does not match"
      end

      { "answer" => record.fetch("answer") }
    end

    def remaining = @records.length
  end
end
