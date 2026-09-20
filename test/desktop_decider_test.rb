# frozen_string_literal: true

require_relative "test_helper"

class DesktopDeciderTest < Minitest::Test
  class AdaptiveTransport
    attr_reader :requests

    def initialize(*choices)
      @choices = choices
      @requests = []
    end

    def call(request)
      @requests << request
      expected_name, choice = @choices.shift
      name = request.dig("question", "name")
      raise "expected #{expected_name}, got #{name}" unless name == expected_name

      keys = request.dig("question", "criteria").keys
      raise "#{choice} was not offered" unless keys.include?(choice)

      confidence = 0.8
      rest = (1.0 - confidence) / (keys.length - 1)
      probabilities = keys.to_h { |key| [key, key == choice ? confidence : rest] }
      { "answer" => { "choice" => choice, "confidence" => confidence, "probabilities" => probabilities } }
    end
  end

  def provider(transport, max_choices: 16, qualified: true)
    Wrangle::DecisionProvider.new(
      transport:,
      capabilities: {
        protocol: Wrangle::DecisionProvider::PROTOCOL, max_choices:, confidence: true,
        hierarchical: true, mutation_qualified: qualified, provider: "fixture", model: "recorded-v1",
        runtime: "ruby", transport: "memory"
      }
    )
  end

  def observation(*candidates)
    { "scope" => { "app" => "Finder" }, "revision" => "r1", "complete" => true,
      "candidates" => candidates }
  end

  def candidate(label, *operations, role: "button", value: nil)
    { "role" => role, "label" => label, "value" => value,
      "states" => ["enabled"], "operations" => operations }
  end

  def test_chooses_only_an_observed_typed_action
    transport = AdaptiveTransport.new(%w[action a1])
    decider = Wrangle::DesktopDecider.new(
      goal: "Open the fixture", literals: {}, provider: provider(transport)
    )

    choice = decider.decide(observation(candidate("Open", "PRESS")))
    assert_equal "PRESS", choice.operation
    assert_equal 1, choice.number
    assert_nil choice.text
    assert choice.action?
    refute choice.terminal?
    assert_equal "fixture", choice.provider
    assert_equal "recorded-v1", choice.model
    assert_equal "PRESS", transport.requests.first.dig("question", "criteria", "a1", "operation")
  end

  def test_text_must_be_an_explicit_literal_or_exact_quoted_goal_span
    one = AdaptiveTransport.new(%w[action a1])
    decider = Wrangle::DesktopDecider.new(
      goal: "Enter the farm name", literals: { farm: "Boehs Farm" }, provider: provider(one)
    )
    choice = decider.decide(observation(candidate("Name", "SET_TEXT", role: "textfield")))
    assert_equal "Boehs Farm", choice.text
    assert_equal "literal:farm", choice.text_source
    assert_equal 1, one.requests.length

    quoted = AdaptiveTransport.new(%w[action a1])
    decider = Wrangle::DesktopDecider.new(
      goal: "Enter 'exact 🚜 text'", literals: {}, provider: provider(quoted)
    )
    choice = decider.decide(observation(candidate("Name", "SET_TEXT", role: "textfield")))
    assert_equal "exact 🚜 text", choice.text
    assert_equal "goal:1", choice.text_source
  end

  def test_provider_selects_among_multiple_exact_literals_without_writing_text
    transport = AdaptiveTransport.new(%w[action a1], ["text", "literal:second"])
    decider = Wrangle::DesktopDecider.new(
      goal: "Choose the requested value", literals: { first: "Alpha", second: "Beta" },
      provider: provider(transport)
    )

    choice = decider.decide(observation(candidate("Name", "SET_TEXT", role: "textfield")))
    assert_equal "Beta", choice.text
    assert_equal "literal:second", choice.text_source
    refute_includes JSON.generate(transport.requests), "Beta"
  end

  def test_missing_text_and_credential_fields_handoff
    missing = AdaptiveTransport.new(%w[action a1])
    choice = Wrangle::DesktopDecider.new(
      goal: "Enter the value", literals: {}, provider: provider(missing)
    ).decide(observation(candidate("Name", "SET_TEXT", role: "textfield")))
    assert_equal "HANDOFF", choice.operation
    assert choice.terminal?

    credential = AdaptiveTransport.new(%w[action HANDOFF])
    choice = Wrangle::DesktopDecider.new(
      goal: "Sign in", literals: { bad: "never" }, provider: provider(credential)
    ).decide(observation(candidate("Password", "SET_TEXT", role: "textfield")))
    assert_equal "HANDOFF", choice.operation
    assert_equal 3, credential.requests.first.dig("question", "criteria").length
  end

  def test_terminal_decisions_have_no_action_target_and_can_see_static_evidence
    transport = AdaptiveTransport.new(%w[action DONE])
    visible = observation(candidate("Open", "PRESS")).merge(
      "tree" => { "role" => "window", "children" => [
        { "role" => "statictext", "name" => "Report status", "value" => "Ready" }
      ] }
    )
    choice = Wrangle::DesktopDecider.new(
      goal: "Confirm the report is ready", literals: {}, provider: provider(transport)
    ).decide(visible)

    assert_equal "DONE", choice.operation
    assert_nil choice.number
    assert choice.terminal?
    evidence = transport.requests.first.dig("state", "visible_evidence")
    assert(evidence["items"].any? { |item| item["label"] == "Report status" && item["value"] == "Ready" })
    refute evidence["explicit_truncation"]
  end

  def test_small_context_provider_uses_hierarchy_without_truncation
    candidates = 6.times.map { |index| candidate("Action #{index + 1}", "PRESS") }
    transport = AdaptiveTransport.new(%w[action_group g2], %w[action a5])
    choice = Wrangle::DesktopDecider.new(
      goal: "Choose action five", literals: {}, provider: provider(transport, max_choices: 4)
    ).decide(observation(*candidates))

    assert_equal 5, choice.number
    assert_equal "PRESS", choice.operation
    assert_equal 2, transport.requests.length
    groups = transport.requests.first.dig("question", "criteria")
    assert_equal %w[g1 g2 g3], groups.keys
    assert_includes JSON.generate(groups["g2"]), "Action 5"
    assert_includes JSON.generate(groups["g2"]), "PRESS"
  end

  def test_selects_bounded_visible_evidence_without_generating_a_summary
    transport = AdaptiveTransport.new(%w[evidence_1 e2], %w[evidence_2 ENOUGH])
    decider = Wrangle::DesktopDecider.new(
      goal: "Report the important status", literals: {}, provider: provider(transport)
    )
    evidence = decider.select_evidence(
      observation(candidate("Alpha", "PRESS"), candidate("Important", "PRESS", value: "Ready"),
                  candidate("Omega", "PRESS")), limit: 3
    )

    labels = evidence.map { |item| item["label"] }
    assert_equal ["Important"], labels
    assert_equal "Ready", evidence.first["value"]
    refute transport.requests.first.dig("question", "criteria").key?("ENOUGH")
    assert transport.requests.last.dig("question", "criteria").key?("ENOUGH")
  end

  def test_decision_state_evidence_is_deterministically_bounded_and_discloses_omissions
    candidates = 60.times.map { |index| candidate("Item #{index + 1}", "PRESS", value: "x" * 600) }
    transport = AdaptiveTransport.new(%w[action DONE])
    decider = Wrangle::DesktopDecider.new(
      goal: "Inspect items", literals: {}, provider: provider(transport, max_choices: 64)
    )

    decider.decide(observation(*candidates))

    evidence = transport.requests.first.dig("state", "visible_evidence")
    assert evidence["explicit_truncation"]
    assert evidence["values_truncated"]
    assert_operator evidence["items"].length, :<=, Wrangle::DesktopDecider::DECISION_EVIDENCE_ITEMS
    assert_operator JSON.generate(evidence["items"]).bytesize, :<=,
                    Wrangle::DesktopDecider::DECISION_EVIDENCE_BYTES
    assert_equal "Item 1", evidence["items"].first["label"]
    assert_equal "Item 60", evidence["items"].last["label"]
  end

  def test_single_or_empty_evidence_needs_no_provider_request
    transport = AdaptiveTransport.new
    decider = Wrangle::DesktopDecider.new(goal: "Report", literals: {}, provider: provider(transport))

    one = decider.select_evidence(observation(candidate("Visible", "PRESS")))
    empty = decider.select_evidence(observation(candidate("", "PRESS", value: nil)))

    labels = one.map { |item| item["label"] }
    assert_equal ["Visible"], labels
    assert_empty empty
    assert_empty transport.requests
  end

  def test_rejects_an_empty_goal
    transport = AdaptiveTransport.new
    assert_raises(ArgumentError) do
      Wrangle::DesktopDecider.new(goal: " ", literals: {}, provider: provider(transport))
    end
  end
end
