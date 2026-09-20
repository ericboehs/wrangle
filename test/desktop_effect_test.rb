# frozen_string_literal: true

require_relative "test_helper"

class DesktopEffectTest < Minitest::Test
  def test_rejects_missing_state_candidate_and_unknown_operation
    before = observation("one", candidate("Open"))

    assert_equal "unverified", verify({ "operation" => "PRESS" }, before, nil)
    assert_equal "unverified", verify({ "operation" => "PRESS" }, before, {})
    assert_equal "unverified", verify({ "operation" => "PRESS" }, before, before)
    assert_equal "unverified", verify(proposal(before, "DRILL"), before, before)
  end

  def test_press_ignores_unrelated_revision_and_focus_changes
    target = candidate("Open", target_key: "native:0:button")
    before = observation("one", target)
    unrelated = observation("two", target, candidate("Unrelated", target_key: "native:1:button"))
    focused = observation("two", target.merge("states" => %w[enabled focused]))

    assert_equal "unchanged", verify(proposal(before, "PRESS"), before, unrelated)
    assert_equal "unchanged", verify(proposal(before, "PRESS"), before, focused)
  end

  def test_press_verifies_only_target_specific_change
    target = candidate("Open", target_key: "native:0:button")
    before = observation("one", target)
    selected = observation("two", target.merge("states" => %w[enabled selected]))
    relabeled = observation("two", target.merge("label" => "Close"))
    disabled = observation("two", target.merge("states" => [], "operations" => []))

    assert_equal "verified", verify(proposal(before, "PRESS"), before, selected)
    assert_equal "verified", verify(proposal(before, "PRESS"), before, relabeled)
    assert_equal "verified", verify(proposal(before, "PRESS"), before, disabled)
    assert_equal "unverified", verify(proposal(before, "PRESS"), before,
                                      observation("one", target.merge("states" => %w[enabled selected])))
  end

  def test_press_disappearance_requires_complete_changed_observation
    target = candidate("Open")
    before = observation("one", target)
    other = candidate("Other")

    assert_equal "verified", verify(proposal(before, "PRESS"), before, observation("two", other))
    assert_equal "unverified", verify(proposal(before, "PRESS"), before,
                                      observation("two", other, complete: false))
    assert_equal "unverified", verify(proposal(before, "PRESS"), before, observation("one", other))
  end

  def test_ambiguous_post_action_target_is_unverified
    target = candidate("Open")
    before = observation("one", target)
    duplicate = target.merge("value" => "changed")
    after = observation("two", target, duplicate)

    assert_equal "unverified", verify(proposal(before, "PRESS"), before, after)

    keyed = target.merge("target_key" => "native:0:button")
    keyed_before = observation("one", keyed)
    keyed_duplicates = observation("two", keyed, keyed.merge("value" => "changed"))
    assert_equal "unverified", verify(proposal(keyed_before, "PRESS"), keyed_before, keyed_duplicates)
  end

  def test_stable_target_key_correlates_effect_without_authorizing_a_new_action
    target = candidate("Open", target_key: "native:0:button")
    before = observation("one", target)
    after = observation(
      "two", target.merge("states" => %w[enabled selected]),
      target.merge("target_key" => "native:1:button")
    )

    assert_equal "verified", verify(proposal(before, "PRESS"), before, after)
  end

  def test_set_text_requires_exact_target_value_and_changed_revision
    target = candidate("Field", role: "textfield", value: "old", operations: %w[SET_TEXT CLEAR])
    before = observation("one", target)
    set = proposal(before, "SET_TEXT", text: "new")

    assert_equal "verified", verify(set, before, observation("two", target.merge("value" => "new")))
    assert_equal "unchanged", verify(set, before, observation("two", target.merge("value" => "other")))
    assert_equal "unverified", verify(set, before, observation("one", target.merge("value" => "new")))
    assert_equal "unverified", verify(set.merge("text" => nil), before,
                                      observation("two", target.merge("value" => "new")))

    already = target.merge("value" => "new")
    assert_equal "unchanged", verify(set.merge("candidate" => already), observation("one", already),
                                     observation("two", already))
  end

  def test_text_effect_does_not_follow_a_changed_or_ambiguous_visible_identity
    target = candidate("Field", role: "textfield", value: "old", operations: %w[SET_TEXT CLEAR],
                                target_key: "native:0:textfield")
    before = observation("one", target)
    set = proposal(before, "SET_TEXT", text: "new")
    relabeled = target.merge("label" => "Other field", "value" => "new")

    assert_equal "unverified", verify(set, before, observation("two", relabeled))

    without_key = target.except("target_key")
    duplicate = without_key.merge("value" => "new")
    ambiguous = observation("two", duplicate, duplicate)
    assert_equal "unverified", verify(set.merge("candidate" => without_key), before, ambiguous)
  end

  def test_clear_requires_observed_string_blankness
    target = candidate("Field", role: "textfield", value: "content", operations: %w[SET_TEXT CLEAR])
    before = observation("one", target)
    clear = proposal(before, "CLEAR")

    assert_equal "verified", verify(clear, before, observation("two", target.merge("value" => "")))
    assert_equal "verified", verify(clear, before, observation("two", target.merge("value" => " \n")))
    assert_equal "unchanged", verify(clear, before, observation("two", target.merge("value" => "still here")))
    assert_equal "unverified", verify(clear, before, observation("two", target.merge("value" => nil)))
    assert_equal "unverified", verify(clear, before, observation("one", target.merge("value" => "")))

    blank = target.merge("value" => "\n")
    assert_equal "unchanged", verify(clear.merge("candidate" => blank), observation("one", blank),
                                     observation("two", blank.merge("value" => "")))
  end

  def test_toggle_requires_the_target_boolean_to_flip
    target = candidate("Choice", role: "checkbox", states: ["enabled"], operations: ["TOGGLE"])
    before = observation("one", target)
    toggle = proposal(before, "TOGGLE")

    assert_equal "verified", verify(toggle, before,
                                    observation("two", target.merge("states" => %w[enabled checked])))
    assert_equal "unchanged", verify(toggle, before,
                                     observation("two", target.merge("states" => %w[enabled focused])))
    assert_equal "unverified", verify(toggle, before,
                                      observation("one", target.merge("states" => %w[enabled checked])))

    numeric = target.merge("value" => 0)
    assert_equal "verified", verify(toggle.merge("candidate" => numeric), observation("one", numeric),
                                    observation("two", numeric.merge("value" => 1)))
    boolean = target.merge("value" => true)
    assert_equal "verified", verify(toggle.merge("candidate" => boolean), observation("one", boolean),
                                    observation("two", boolean.merge("value" => false)))
    assert_equal "unverified", verify(toggle.merge("candidate" => target.merge("role" => "button")), before,
                                      observation("two", target.merge("role" => "button")))
    relabeled = target.merge("target_key" => "native:0:checkbox", "label" => "Other")
    keyed_toggle = toggle.merge("candidate" => target.merge("target_key" => "native:0:checkbox"))
    assert_equal "unverified", verify(keyed_toggle, before, observation("two", relabeled))
  end

  def test_expand_and_collapse_require_the_requested_expanded_state
    collapsed = candidate("Section", states: ["enabled"], operations: ["EXPAND"])
    expanded = collapsed.merge("states" => %w[enabled expanded], "operations" => ["COLLAPSE"])
    expand = { "operation" => "EXPAND", "candidate" => collapsed }
    collapse = { "operation" => "COLLAPSE", "candidate" => expanded }

    assert_equal "verified", verify(expand, observation("one", collapsed), observation("two", expanded))
    assert_equal "unchanged", verify(expand, observation("one", collapsed), observation("two", collapsed))
    assert_equal "verified", verify(collapse, observation("one", expanded), observation("two", collapsed))
    assert_equal "unchanged", verify(collapse, observation("one", expanded), observation("two", expanded))
    assert_equal "unverified", verify(expand, observation("one", collapsed), observation("one", expanded))
    assert_equal "unverified", verify(expand.merge("candidate" => expanded), observation("one", expanded),
                                      observation("two", expanded))
    assert_equal "unverified", verify(expand, observation("one", collapsed),
                                      observation("two", collapsed.except("states")))
  end

  def test_state_operations_do_not_treat_target_disappearance_as_success
    %w[SET_TEXT CLEAR TOGGLE EXPAND COLLAPSE].each do |operation|
      target = candidate("Target", role: operation == "TOGGLE" ? "checkbox" : "textfield",
                                   operations: [operation])
      before = observation("one", target)
      assert_equal "unverified", verify(proposal(before, operation, text: operation == "SET_TEXT" ? "x" : nil),
                                        before, observation("two", candidate("Other")))
    end
  end

  def test_tree_state_can_verify_a_target_that_is_no_longer_actionable
    target = candidate("Open", target_key: "native:0:button")
    before = observation("one", target)
    tree = {
      "role" => "window", "name" => "Fixture", "states" => [],
      "children" => [{ "role" => "button", "name" => "Open", "states" => [], "children" => [] }]
    }
    after = observation("two", tree:)

    assert_equal "verified", verify(proposal(before, "PRESS"), before, after)
  end

  def test_partial_observation_can_verify_a_directly_observed_target_state
    target = candidate("Choice", role: "checkbox", states: ["enabled"], operations: ["TOGGLE"])
    before = observation("one", target)
    after = observation("two", target.merge("states" => %w[enabled checked]), complete: false)

    assert_equal "verified", verify(proposal(before, "TOGGLE"), before, after)
  end

  private

  def verify(proposal, before, after) = Wrangle::DesktopEffect.verify(proposal, before, after)

  def proposal(observation, operation, text: nil)
    { "operation" => operation, "candidate" => observation.fetch("candidates").first,
      "text" => text }.compact
  end

  def candidate(label, role: "button", value: nil, states: ["enabled"], operations: ["PRESS"],
                target_key: nil)
    {
      "role" => role, "label" => label, "value" => value, "states" => states,
      "operations" => operations, "target_key" => target_key
    }.compact
  end

  def observation(revision, *candidates, complete: true, tree: nil)
    {
      "revision" => revision, "complete" => complete,
      "coverage" => { "truncated" => !complete }, "candidates" => candidates,
      "tree" => tree
    }.compact
  end
end
