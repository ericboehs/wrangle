# frozen_string_literal: true

require_relative "test_helper"

class DecisionProviderTest < Minitest::Test
  class FakeJev
    attr_reader :request

    def ask(**request)
      @request = request
      { "answers" => { "next" => answer(%w[a b], "a") } }
    end

    def answer(keys, choice)
      { "choice" => choice, "confidence" => 0.7,
        "probabilities" => keys.to_h { |key| [key, key == choice ? 0.7 : 0.3] } }
    end
  end

  def capabilities(**overrides)
    {
      protocol: Wrangle::DecisionProvider::PROTOCOL, max_choices: 8, confidence: true,
      hierarchical: true, mutation_qualified: true, provider: "replay", model: "fixture",
      runtime: "ruby", transport: "memory"
    }.merge(overrides)
  end

  def answer(keys, choice, confidence: 0.8)
    rest = keys.length == 1 ? 0.0 : (1.0 - confidence) / (keys.length - 1)
    { "choice" => choice, "confidence" => confidence,
      "probabilities" => keys.to_h { |key| [key, key == choice ? confidence : rest] } }
  end

  def test_negotiates_capabilities_and_validates_an_exact_distribution
    transport = Wrangle::ReplayChoiceTransport.new([
                                                     { "name" => "next", "answer" => answer(%w[a b c], "b") }
                                                   ])
    provider = Wrangle::DecisionProvider.new(transport:, capabilities: capabilities)

    decision = provider.choose(state: { "safe" => true }, name: "next",
                               criteria: { "a" => "A", "b" => "B", "c" => "C" }, instructions: "pick")
    assert_equal "b", decision.choice
    assert_in_delta 0.8, decision.confidence
    assert_operator decision.latency_ms, :>=, 0
    assert provider.mutation_qualified?
    assert_equal 0, transport.remaining

    negotiated = Wrangle::DecisionProvider::Capabilities.new(**capabilities)
    copy = Wrangle::DecisionProvider.new(transport: ->(_) { raise "unused" }, capabilities: negotiated)
    assert_same negotiated, copy.capabilities
  end

  def test_fails_closed_on_incompatible_capabilities_or_choice_counts
    assert_raises(Wrangle::ConfigurationError) do
      Wrangle::DecisionProvider.new(
        transport: ->(_) { raise "unused" }, capabilities: capabilities(protocol: "other")
      )
    end

    provider = Wrangle::DecisionProvider.new(
      transport: ->(_) { raise "unused" }, capabilities: capabilities(max_choices: 2)
    )
    assert_raises(ArgumentError) do
      provider.choose(state: {}, name: "one", criteria: { "a" => "A" }, instructions: "pick")
    end
    assert_raises(Wrangle::ProviderError) do
      provider.choose(state: {}, name: "many", criteria: { "a" => "A", "b" => "B", "c" => "C" },
                      instructions: "pick")
    end
  end

  def test_rejects_malformed_unoffered_and_non_argmax_answers
    bad = [
      nil,
      answer(%w[a b], "a").merge("choice" => "z"),
      answer(%w[a b], "a").merge("probabilities" => { "a" => 0.8 }),
      { "choice" => "a", "confidence" => 2, "probabilities" => { "a" => 0.8, "b" => 0.2 } },
      { "choice" => "a", "confidence" => 0.4, "probabilities" => { "a" => 0.4, "b" => 0.6 } }
    ]
    bad.each do |value|
      provider = Wrangle::DecisionProvider.new(
        transport: ->(_) { { "answer" => value } }, capabilities: capabilities
      )
      assert_raises(Wrangle::ProviderError) do
        provider.choose(state: {}, name: "next", criteria: { "a" => "A", "b" => "B" }, instructions: "pick")
      end
    end

    provider = Wrangle::DecisionProvider.new(transport: ->(_) {}, capabilities: capabilities)
    assert_raises(Wrangle::ProviderError) do
      provider.choose(state: {}, name: "next", criteria: { "a" => "A", "b" => "B" }, instructions: "pick")
    end
  end

  def test_wraps_transport_failures_without_exposing_the_message
    provider = Wrangle::DecisionProvider.new(
      transport: ->(_) { raise IOError, "private literal" }, capabilities: capabilities
    )
    error = assert_raises(Wrangle::ProviderError) do
      provider.choose(state: {}, name: "next", criteria: { "a" => "A", "b" => "B" }, instructions: "pick")
    end
    assert_equal "Decision provider failed: IOError", error.message
  end

  def test_jev_transport_maps_the_vendor_neutral_question
    jev = FakeJev.new
    provider = Wrangle::DecisionProvider.new(
      transport: Wrangle::JevChoiceTransport.new(jev), capabilities: capabilities
    )
    decision = provider.choose(state: { "page" => "state" }, name: "next",
                               criteria: { "a" => "A", "b" => "B" }, instructions: "pick")

    assert_equal "a", decision.choice
    assert_equal({ "page" => "state" }, jev.request[:state])
    assert_equal "choice", jev.request.dig(:questions, "next", "type")
  end

  def test_replay_loads_canonical_provider_cases_as_a_recorded_benchmark
    path = File.expand_path("fixtures/provider_conformance.jsonl", __dir__)
    transport = Wrangle::ReplayChoiceTransport.load(path)
    test_case = Wrangle::ProviderQualification.load(path).first
    request = test_case.fetch("request")

    result = transport.call("question" => { "name" => request.fetch("name") })
    assert_equal test_case.fetch("answer"), result["answer"]
    assert_equal Wrangle::ProviderQualification.load(path).length - 1, transport.remaining
  end

  def test_replay_loads_plain_trace_records
    Dir.mktmpdir("wrangle-replay") do |directory|
      path = File.join(directory, "trace.jsonl")
      File.write(path, JSON.generate("name" => "next", "answer" => answer(%w[a b], "a")) << "\n")
      transport = Wrangle::ReplayChoiceTransport.load(path)

      result = transport.call("question" => { "name" => "next" })
      assert_equal "a", result.dig("answer", "choice")
    end
  end

  def test_replay_trace_checks_question_identity_and_exhaustion
    transport = Wrangle::ReplayChoiceTransport.new([{ "name" => "wrong", "answer" => {} }])
    assert_raises(Wrangle::ProviderError) { transport.call("question" => { "name" => "next" }) }
    empty = Wrangle::ReplayChoiceTransport.new([])
    assert_raises(Wrangle::ProviderError) { empty.call("question" => { "name" => "next" }) }
  end
end
