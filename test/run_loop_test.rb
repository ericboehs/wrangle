# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/scripted_jev"

# The run loop is the part that acts without asking, so these tests are about the rules that decide
# when it may keep going: does a plan advance only on a finished leg, does churn get charged to the
# budget, and is a low-confidence stop trusted. Every bug these cover was first seen on a live page.
class RunLoopTest < Minitest::Test
  include BridgeHelpers

  FILL = "Destination"
  CLICK = "Find stays"

  def setup
    super
    @socket = File.join(@tmpdir, "run.sock")
  end

  def teardown
    @thread&.kill
    @thread = nil
    super
  end

  def serving(turns, stale_acts: 0, **config)
    @jev = ScriptedJev.new(turns)
    session = dedicated(**config)
    session = FlakySession.new(session, stale_acts: stale_acts) if stale_acts.positive?
    server = Wrangle::SessionServer.new(@socket, {}, session: session, jev: @jev)
    @thread = Thread.new { server.run }
    @thread.abort_on_exception = false
    client = Wrangle::SessionClient.new(@socket)
    sleep 0.02 until File.socket?(@socket)
    client
  end

  def run_plan(client, plan:, **params)
    client.call("run", goal: plan.first, plan: plan, execute: true, literals: { "destination" => "Lisbon" },
                       settle: 0, steady: 0.0, **params).fetch("value")
  end

  def operations(value) = value.fetch("steps").map { _1["operation"] }
  def goals(value) = value.fetch("steps").select { _1["operation"] == "GOAL" }.map { _1["action"] }
  def executed(value) = value.fetch("steps").select { _1["executed"] }

  # --- plan advancement ---------------------------------------------------------------------

  def test_a_plan_runs_every_leg_in_order_and_marks_each_one
    client = serving([{ operation: "CLICK", target: CLICK, confidence: 0.9 },
                      { operation: "DONE", confidence: 0.9 },
                      { operation: "TYPE_TEXT", target: FILL, confidence: 0.9 },
                      { operation: "DONE", confidence: 0.9 }])

    value = run_plan(client, plan: ["Press the button", "Type the destination"])

    assert_equal ["Press the button", "Type the destination"], goals(value)
    assert_equal([CLICK, FILL], executed(value).map { _1["action"] })
    assert_equal "DONE", value["stopped"]
  end

  def test_each_leg_is_decided_against_its_own_goal
    client = serving([{ operation: "CLICK", target: CLICK, confidence: 0.9 },
                      { operation: "DONE", confidence: 0.9 },
                      { operation: "DONE", confidence: 0.9 }])

    run_plan(client, plan: ["First goal", "Second goal"])

    assert_equal(["First goal", "First goal", "Second goal"], @jev.asked.map { _1[:goal] })
  end

  def test_a_leg_that_cannot_finish_stops_the_plan_rather_than_guessing_past_it
    client = serving([{ operation: "BLOCKED", confidence: 0.9 }] * 4)

    value = run_plan(client, plan: ["Impossible leg", "Never reached"])

    assert_equal ["Impossible leg"], goals(value)
    assert_equal "BLOCKED", value["stopped"]
    assert_empty executed(value)
  end

  def test_a_single_goal_still_runs_without_plan_markers
    client = serving([{ operation: "CLICK", target: CLICK, confidence: 0.9 },
                      { operation: "DONE", confidence: 0.9 }])

    value = client.call("run", goal: "Press the button", execute: true, settle: 0, steady: 0.0).fetch("value")

    refute_includes operations(value), "GOAL"
    assert_equal 1, executed(value).length
  end

  # --- budget accounting --------------------------------------------------------------------

  def test_the_leg_budget_caps_the_actions_taken
    turns = Array.new(5) { { operation: "CLICK", target: CLICK, confidence: 0.9 } }
    client = serving(turns)

    value = run_plan(client, plan: ["Keep clicking"], leg_steps: 2, steps: 10)

    assert_equal 2, executed(value).length
  end

  # A stale page is churn, not work. Charging it to the leg is how a form that flickers runs out of
  # allowance one click before it finishes.
  def test_a_stale_retry_does_not_spend_the_leg_budget
    client = serving([{ operation: "CLICK", target: CLICK, confidence: 0.9 },
                      { operation: "CLICK", target: CLICK, confidence: 0.9 },
                      { operation: "CLICK", target: CLICK, confidence: 0.9 }],
                     stale_acts: 1)

    value = run_plan(client, plan: ["Keep clicking"], leg_steps: 2, steps: 10)

    assert_includes operations(value), "RESTALE"
    assert_equal 2, executed(value).length
  end

  def test_a_page_that_never_settles_hands_back_instead_of_spinning
    turns = Array.new(6) { { operation: "CLICK", target: CLICK, confidence: 0.9 } }
    client = serving(turns, stale_acts: 6)

    value = run_plan(client, plan: ["Click something"], leg_steps: 4, steps: 10)

    assert_empty executed(value)
    assert_equal "HANDOFF", value["stopped"]
    assert_equal 4, operations(value).count("RESTALE")
  end

  # --- the confidence floor ------------------------------------------------------------------

  def test_low_confidence_is_reconsidered_once_before_handing_back
    client = serving([{ operation: "CLICK", target: CLICK, confidence: 0.2 },
                      { operation: "CLICK", target: CLICK, confidence: 0.2 }])

    value = run_plan(client, plan: ["Press the button"], min_confidence: 0.5)

    assert_equal 2, @jev.asked.length, "the loop should look again before giving up"
    assert_equal 1, operations(value).count("HANDOFF"), "only the final doubt is reported"
    assert_empty executed(value)
  end

  def test_a_second_look_that_clears_the_floor_acts_normally
    client = serving([{ operation: "CLICK", target: CLICK, confidence: 0.2 },
                      { operation: "CLICK", target: CLICK, confidence: 0.9 },
                      { operation: "DONE", confidence: 0.9 }])

    value = run_plan(client, plan: ["Press the button"], min_confidence: 0.5)

    assert_equal 1, executed(value).length
    refute_includes operations(value), "HANDOFF"
  end

  # DONE and BLOCKED are both stops, and both get a second look — but being wrong about them costs
  # very different amounts, so only one of them may end the plan on a guess.
  def test_an_uncertain_done_still_advances_the_plan
    client = serving([{ operation: "DONE", confidence: 0.3 },
                      { operation: "DONE", confidence: 0.3 },
                      { operation: "CLICK", target: CLICK, confidence: 0.9 },
                      { operation: "DONE", confidence: 0.9 }])

    value = run_plan(client, plan: ["Maybe already done", "Do the real work"], min_confidence: 0.5)

    assert_equal ["Maybe already done", "Do the real work"], goals(value)
    assert_equal([CLICK], executed(value).map { _1["action"] })
  end

  def test_an_uncertain_blocked_hands_back_and_abandons_the_rest_of_the_plan
    client = serving([{ operation: "BLOCKED", confidence: 0.3 }] * 4)

    value = run_plan(client, plan: ["Might be stuck", "Never reached"], min_confidence: 0.5)

    assert_equal ["Might be stuck"], goals(value)
    assert_equal "HANDOFF", value["stopped"]
    assert_equal 4, @jev.asked.length, "a weak BLOCKED should be looked at again before it is believed"
  end

  # Amazon's filter sidebar renders after its results do, and inside a plan the next leg starts
  # milliseconds later — so the control a leg needs can be genuinely absent when Jev first looks,
  # and present a moment afterwards. Believing the first look ended the run one click in.
  def test_a_control_that_has_not_rendered_yet_is_waited_for_rather_than_called_a_dead_end
    client = serving([{ operation: "BLOCKED", confidence: 0.3 },
                      { operation: "CLICK", target: CLICK, confidence: 0.9 },
                      { operation: "DONE", confidence: 0.9 }])

    value = run_plan(client, plan: ["Click it once it arrives"], min_confidence: 0.5)

    assert_equal "DONE", value["stopped"]
    assert_equal([CLICK], executed(value).map { _1["action"] })
    assert_includes operations(value), "RELOOK"
  end

  # A floor low enough to let an underconfident click through must not also lower the bar for the one
  # decision that throws away every remaining leg.
  def test_a_low_floor_does_not_make_it_easier_to_abandon_the_run
    client = serving([{ operation: "BLOCKED", confidence: 0.45 }] * 4)

    value = run_plan(client, plan: ["Might be stuck", "Never reached"], min_confidence: 0.4)

    assert_equal "HANDOFF", value["stopped"], "0.45 clears the caller's floor but not the BLOCKED floor"
  end

  # Wikipedia's search link navigates, and the next leg starts while the new document is still
  # loading: "the search box is not here" was 76% sure and wrong. Confidence does not help, because a
  # half-loaded page does not look ambiguous, it looks definite — and looking again makes the model
  # surer, not less. So a leg that has not acted yet confirms a BLOCKED however sure it is.
  def test_a_confident_blocked_on_a_leg_that_has_not_acted_is_confirmed_before_it_is_believed
    client = serving([{ operation: "BLOCKED", confidence: 0.9 }] * 4)

    value = run_plan(client, plan: ["Truly stuck"], min_confidence: 0.5)

    assert_equal 4, @jev.asked.length
    assert_equal "BLOCKED", value["stopped"]
  end

  # The confirming look is spent once per leg, not before every stop the leg reports.
  def test_a_blocked_after_the_leg_has_already_worked_is_taken_at_its_word
    client = serving([{ operation: "CLICK", target: CLICK, confidence: 0.9 },
                      { operation: "BLOCKED", confidence: 0.9 }])

    value = run_plan(client, plan: ["Got somewhere, then stuck"], min_confidence: 0.5)

    assert_equal 2, @jev.asked.length
    assert_equal "BLOCKED", value["stopped"]
  end

  # --- claiming to be finished ----------------------------------------------------------------

  # DONE is the model's report on its own work, made from the same look that proposed the actions,
  # and an Amazon plan reported success with the filter it was asked for never applied. The
  # verification head asked in the same request has no action to gain by agreeing.
  def test_a_disputed_done_does_not_end_the_leg
    client = serving([{ operation: "DONE", confidence: 0.9, met: false, met_confidence: 0.9 },
                      { operation: "CLICK", target: CLICK, confidence: 0.9 },
                      { operation: "DONE", confidence: 0.9 }])

    value = run_plan(client, plan: ["Actually do the thing"])

    assert_includes operations(value), "UNPROVEN"
    assert_equal([CLICK], executed(value).map { _1["action"] })
    assert_equal "DONE", value["stopped"]
  end

  # A claim that keeps failing to check out, after the page has been given time to catch up, is a
  # standoff between the actor and the page that nothing in the loop can settle.
  def test_a_claim_disputed_to_the_end_hands_back_and_abandons_the_rest_of_the_plan
    client = serving([{ operation: "DONE", confidence: 0.9, met: false, met_confidence: 0.9 }] * 3)

    value = run_plan(client, plan: ["Claim it", "Never reached"], min_confidence: 0.5)

    assert_equal ["Claim it"], goals(value)
    assert_equal "HANDOFF", value["stopped"]
  end

  # A verifier that is merely unsure is noise, not evidence. Only a confident "no" overrules a claim,
  # for the same reason a low-confidence action is not executed.
  def test_an_unsure_dispute_does_not_overrule_the_claim
    client = serving([{ operation: "DONE", confidence: 0.9, met: false, met_confidence: 0.5 }])

    value = run_plan(client, plan: ["Say it is done"], min_confidence: 0.5)

    assert_equal 1, @jev.asked.length
    assert_equal "DONE", value["stopped"]
  end

  # --- typing --------------------------------------------------------------------------------

  def test_a_fill_without_a_supplied_literal_asks_for_one_instead_of_inventing_text
    client = serving([{ operation: "TYPE_TEXT", target: FILL, confidence: 0.9 }])

    value = client.call("run", goal: "Type something", plan: ["Type something"], execute: true,
                               literals: {}, settle: 0, steady: 0.0).fetch("value")

    assert_equal "HANDOFF", value["stopped"]
    assert_match(/--literal/, value["steps"].last["action"])
    assert_empty executed(value)
  end

  def test_run_refuses_to_touch_the_page_without_execute
    client = serving([])

    reply = client.call("run", goal: "Press the button", plan: ["Press the button"], settle: 0)

    refute reply["ok"]
    assert_match(/execute/, reply["error"].to_s)
  end
end
