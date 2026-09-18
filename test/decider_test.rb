# frozen_string_literal: true

require "test_helper"

# The decider is the boundary between a model's answer and an action on someone's page, so most of
# these tests are about refusing: an answer that does not check out must raise rather than resolve
# into something clickable. The rest are about what Jev is asked, because a head that is never asked
# cannot be read, and a head that is read without being named could act on its own.
class DeciderTest < Minitest::Test
  PAGE = {
    "url" => "https://fixture.test/stays", "title" => "Stays", "text" => "Find a place",
    "actions" => [
      { "id" => "e1", "node" => 1, "kind" => "click", "label" => "Find stays" },
      { "id" => "e2", "node" => 2, "kind" => "fill", "label" => "Where to?", "value" => "" },
      { "id" => "wait", "kind" => "wait", "label" => "Wait for the page to update" }
    ]
  }.freeze

  def decider(goal = "Find a place to stay")
    Wrangle::Decider.new(goal: goal)
  end

  def asked(chooser = decider)
    chooser.questions(PAGE)
  end

  # Spreads the remaining mass evenly over the other options. A lone option holds all of it whatever
  # the confidence: confidence and probability are different claims, and only the second has to sum
  # to one.
  def answer(offered, choice, confidence)
    others = offered - [choice]
    if others.empty?
      return { "type" => "choice", "choice" => choice, "confidence" => confidence,
               "probabilities" => { choice => 1.0 } }
    end

    share = (1.0 - confidence) / others.length
    probabilities = offered.to_h { |key| [key, key == choice ? confidence : share] }
    { "type" => "choice", "choice" => choice, "confidence" => confidence, "probabilities" => probabilities }
  end

  def answers(chooser, operation:, target: nil, met: "YES", confidence: 0.9)
    questions = chooser.questions(PAGE)
    built = { "operation" => answer(questions["operation"]["criteria"].keys, operation, confidence),
              "goal_met" => answer(%w[YES NO], met, 0.9) }
    if target
      head = "#{operation.downcase}_target"
      built[head] = answer(questions[head]["criteria"].keys, target, confidence)
    end
    { "answers" => built }
  end

  # --- what gets asked ---------------------------------------------------------------------------

  def test_every_operation_and_a_target_for_each_are_asked_in_one_request
    questions = asked

    assert_equal %w[operation goal_met click_target type_text_target], questions.keys
    assert_includes questions["operation"]["criteria"].keys, "CLICK"
    assert_includes questions["operation"]["criteria"].keys, "WAIT"
    assert_equal %w[DONE BLOCKED], questions["operation"]["criteria"].keys.last(2)
  end

  # The verification head weighs the goal against the page. It is asked every time so that it costs
  # no extra round trip, and it offers no action, so reading it can never cause one.
  def test_the_verification_head_is_asked_alongside_and_can_only_answer_yes_or_no
    questions = asked

    assert_equal %w[YES NO], questions["goal_met"]["criteria"].keys
    assert_equal "Find a place to stay", questions["goal_met"]["instructions"]["goal"]
    refute_match(/CLICK|TYPE_TEXT/, questions["goal_met"]["instructions"]["rules"])
  end

  def test_a_target_question_offers_only_the_elements_that_support_that_operation
    questions = asked

    assert_equal(["Find stays"], questions["click_target"]["criteria"].values.map { _1["element"] })
    assert_equal(["Where to?"], questions["type_text_target"]["criteria"].values.map { _1["element"] })
  end

  # --- what comes back ---------------------------------------------------------------------------

  def test_an_operation_and_its_named_target_resolve_to_one_action
    chooser = decider
    choice = chooser.resolve(answers(chooser, operation: "CLICK", target: "1"), PAGE)

    assert_equal "CLICK", choice.operation
    assert_equal "Find stays", choice.label
    assert_in_delta 0.9, choice.confidence
    assert_in_delta 0.9, choice.target_confidence
    refute_predicate choice, :stop?
  end

  # Every head is answered, but only the one the operation names is read. An unused head holding a
  # different element must not be able to reach the page.
  def test_a_head_the_operation_did_not_name_is_never_read
    chooser = decider
    reply = answers(chooser, operation: "CLICK", target: "1")
    reply["answers"]["type_text_target"] = { "type" => "choice", "choice" => "nonsense",
                                             "confidence" => 2.0, "probabilities" => { "nope" => 3.0 } }

    assert_equal "Find stays", chooser.resolve(reply, PAGE).label
  end

  def test_stopping_operations_resolve_without_a_target
    chooser = decider
    choice = chooser.resolve(answers(chooser, operation: "DONE"), PAGE)

    assert_predicate choice, :stop?
    assert_nil choice.target_confidence
    assert_equal "DONE", choice.label
  end

  def test_a_verdict_of_no_is_carried_with_its_confidence_and_disputes_above_the_floor
    chooser = decider
    choice = chooser.resolve(answers(chooser, operation: "DONE", met: "NO"), PAGE)

    refute choice.met
    assert_in_delta 0.9, choice.met_confidence
    assert choice.disputed?(0.6)
  end

  def test_an_unsure_verdict_disputes_nothing
    chooser = decider
    reply = answers(chooser, operation: "DONE", met: "NO")
    reply["answers"]["goal_met"] = answer(%w[YES NO], "NO", 0.5)

    refute chooser.resolve(reply, PAGE).disputed?(0.6)
  end

  # A reply that lost the verification head still decides; it simply disputes nothing. Losing the
  # ability to act because one head went missing would be the more expensive failure.
  def test_a_missing_verification_head_leaves_the_decision_intact
    chooser = decider
    reply = answers(chooser, operation: "CLICK", target: "1")
    reply["answers"].delete("goal_met")
    choice = chooser.resolve(reply, PAGE)

    assert_equal "Find stays", choice.label
    assert_nil choice.met
    refute choice.disputed?(0.0)
  end

  # --- what gets refused -------------------------------------------------------------------------

  def refusal(reply)
    chooser = decider
    chooser.questions(PAGE)
    assert_raises(Wrangle::JevError) { chooser.resolve(reply, PAGE) }
  end

  def test_a_reply_without_answers_is_refused
    assert_match(/without answers/, refusal({ "model" => "jev" }).message)
  end

  # No probabilities at all is not a weak answer, it is not an answer. There is nothing to check the
  # named choice against, so there is no way to tell a decision from a guess.
  def test_an_answer_with_no_distribution_at_all_is_refused
    chooser = decider
    reply = answers(chooser, operation: "CLICK", target: "1")
    reply["answers"]["operation"].delete("probabilities")

    error = assert_raises(Wrangle::JevError) { chooser.resolve(reply, PAGE) }

    assert_match(/malformed/, error.message)
  end

  def test_an_answer_that_is_not_even_a_hash_is_refused
    chooser = decider
    reply = answers(chooser, operation: "CLICK", target: "1")
    reply["answers"]["operation"] = "CLICK"

    assert_raises(Wrangle::JevError) { chooser.resolve(reply, PAGE) }
  end

  def test_an_answer_naming_something_that_was_not_offered_is_refused
    chooser = decider
    reply = answers(chooser, operation: "CLICK", target: "1")
    reply["answers"]["operation"]["choice"] = "LAUNCH_MISSILES"

    assert_raises(Wrangle::JevError) { chooser.resolve(reply, PAGE) }
  end

  def test_an_answer_whose_distribution_does_not_cover_the_options_is_refused
    chooser = decider
    reply = answers(chooser, operation: "CLICK", target: "1")
    reply["answers"]["operation"]["probabilities"] = { "CLICK" => 1.0 }

    assert_raises(Wrangle::JevError) { chooser.resolve(reply, PAGE) }
  end

  # Halved, not doubled: every number stays a legal probability and only their total is wrong, which
  # is the rule under test. Doubling would be caught by the range check instead.
  def test_an_answer_whose_probabilities_do_not_sum_to_one_is_refused
    chooser = decider
    reply = answers(chooser, operation: "CLICK", target: "1")
    reply["answers"]["operation"]["probabilities"].transform_values! { |value| value / 2 }

    assert_raises(Wrangle::JevError) { chooser.resolve(reply, PAGE) }
  end

  # The named choice has to be the argmax of the distribution it came with. An answer that says CLICK
  # while its own numbers say WAIT is not a decision, it is a contradiction.
  def test_an_answer_that_is_not_the_argmax_of_its_own_distribution_is_refused
    chooser = decider
    questions = chooser.questions(PAGE)
    offered = questions["operation"]["criteria"].keys
    reply = { "answers" => { "operation" => answer(offered, "CLICK", 0.9).merge("choice" => "WAIT"),
                             "goal_met" => answer(%w[YES NO], "YES", 0.9) } }

    assert_raises(Wrangle::JevError) { chooser.resolve(reply, PAGE) }
  end

  def test_an_answer_carrying_a_number_that_is_not_a_probability_is_refused
    chooser = decider
    reply = answers(chooser, operation: "CLICK", target: "1")
    reply["answers"]["operation"]["confidence"] = Float::NAN

    assert_raises(Wrangle::JevError) { chooser.resolve(reply, PAGE) }
  end
end
