# frozen_string_literal: true

require_relative "test_helper"

class DesktopObservationTest < Minitest::Test
  def setup
    @scope = Wrangle::MacOSDriver::Scope.new(
      id: "scope-1", root: "w-1", app: "Finder", bundle_id: "com.apple.finder", pid: 42,
      process_instance: "proc-42", bounds: {}, display_id: "display-1", attached_at: "now"
    )
    @window = { "id" => "w-1", "process_instance" => "proc-42", "bounds" => { "x" => 1 },
                "focused" => true, "visible" => true, "title" => "not copied here" }
  end

  def test_normalizes_typed_candidates_and_retains_the_tree
    snapshot = snapshot_with(
      { "role" => "window", "name" => "Fixture", "children" => [
        { "ref_id" => "@s:e1", "role" => "textfield", "name" => "Search", "value" => "query",
          "states" => ["enabled"] },
        { "ref_id" => "@s:e2", "role" => "checkbox", "name" => "Show", "value" => false },
        { "ref_id" => "@s:e3", "role" => "listbox", "name" => "Choice" },
        { "ref_id" => "@s:e4", "role" => "group", "name" => "More", "children_count" => 12 },
        { "role" => "statictext", "name" => "Context only", "children" => ["ignored"] },
        { "ref_id" => "@s:window", "role" => "window", "name" => "No action" },
        { "ref_id" => "@s:empty", "name" => "No role" },
        { "ref_id" => "@s:e5", "role" => "button", "name" => "Object value", "value" => { "x" => 1 } }
      ] }
    )

    state = Wrangle::DesktopObservation.new(scope: @scope, snapshot:, window: @window).state

    assert_equal "wrangle.observation.v1", state["schema"]
    assert_equal "scope-1", state.dig("scope", "id")
    refute_includes state["window"], "title"
    assert_equal snapshot["tree"], state["tree"]
    evidence = Wrangle::DesktopObservation.evidence_items(state)
    assert(evidence.any? { |item| item["label"] == "Context only" && item["role"] == "statictext" })
    assert_equal 5, state["candidates"].length
    assert_equal %w[SET_TEXT CLEAR PRESS], state["candidates"][0]["operations"]
    assert_equal %w[TOGGLE PRESS], state["candidates"][1]["operations"]
    assert_equal ["PRESS"], state["candidates"][2]["operations"]
    assert_equal %w[DRILL PRESS], state["candidates"][3]["operations"]
    assert_equal ["PRESS"], state["candidates"][4]["operations"]
    assert_nil state["candidates"][4]["value"]
    assert state.dig("coverage", "truncated")
    assert_equal "not_used", state.dig("coverage", "ocr")
    assert_match(/\A[0-9a-f]{24}\z/, state["revision"])
  end

  def test_omits_window_controls_and_disabled_mutations_from_agent_candidates
    snapshot = snapshot_with(
      { "role" => "window", "children" => [
        { "ref_id" => "@s:e1", "role" => "button", "name" => "Close" },
        { "ref_id" => "@s:e2", "role" => "button", "subrole" => "AXMinimizeButton", "name" => "" },
        { "ref_id" => "@s:e3", "role" => "button", "name" => "Continue", "states" => ["disabled"] },
        { "ref_id" => "@s:quit", "role" => "menuitem", "name" => "Quit Finder" },
        { "ref_id" => "@s:e4", "role" => "group", "name" => "Disabled details",
          "states" => ["disabled"], "children_count" => 2 }
      ] }
    )

    state = Wrangle::DesktopObservation.new(scope: @scope, snapshot:, window: @window).state

    assert_equal 1, state["candidates"].length
    assert_equal "Disabled details", state.dig("candidates", 0, "label")
    assert_equal ["DRILL"], state.dig("candidates", 0, "operations")
  end

  def test_native_snapshot_uses_only_observed_operations_and_opaque_target_identity
    snapshot = snapshot_with(
      { "role" => "window", "children" => [
        { "ref_id" => "@nnative:e1", "role" => "button", "subrole" => "closebutton",
          "name" => "Close", "operations" => [], "target_key" => "native:close" },
        { "ref_id" => "@nnative:e2", "role" => "textfield", "name" => "Message",
          "operations" => %w[SET_TEXT CLEAR UNSAFE], "target_key" => "native:message",
          "children_count" => 2 }
      ] }
    ).merge("provenance" => %w[ax macos_helper_native])

    state = Wrangle::DesktopObservation.new(scope: @scope, snapshot:, window: @window).state

    assert_equal 1, state["candidates"].length
    candidate = state["candidates"].first
    assert_equal %w[DRILL SET_TEXT CLEAR], candidate["operations"]
    assert_equal "native:message", candidate["target_key"]
    assert_equal "closebutton", state.dig("tree", "children", 0, "subrole")
    assert_equal %w[ax macos_helper_native], state.dig("coverage", "provenance")
  end

  def test_revision_is_deterministic_and_changes_with_observed_state
    one = Wrangle::DesktopObservation.new(scope: @scope, snapshot: snapshot_with(tree), window: @window)
    two = Wrangle::DesktopObservation.new(scope: @scope, snapshot: snapshot_with(tree, id: "s2"), window: @window)
    changed = Wrangle::DesktopObservation.new(scope: @scope, snapshot: snapshot_with(tree("Other")), window: @window)

    assert_equal one.revision, two.revision
    refute_equal one.revision, changed.revision
    assert_equal one.candidates, one.state["candidates"]
    refute one.state.dig("coverage", "truncated")
  end

  def test_revision_ignores_volatile_non_actionable_context
    first_tree = tree.merge("children" => tree["children"] + [{ "role" => "statictext", "name" => "993.3 GB" }])
    second_tree = tree.merge("children" => tree["children"] + [{ "role" => "statictext", "name" => "993 GB" }])
    first = Wrangle::DesktopObservation.new(scope: @scope, snapshot: snapshot_with(first_tree), window: @window)
    second = Wrangle::DesktopObservation.new(scope: @scope, snapshot: snapshot_with(second_tree), window: @window)

    assert_equal first.revision, second.revision
    refute_equal first.state["tree"], second.state["tree"]
  end

  def test_driver_incompleteness_is_disclosed
    snapshot = snapshot_with(tree).merge("complete" => false)
    state = Wrangle::DesktopObservation.new(scope: @scope, snapshot:, window: @window).state

    assert state.dig("coverage", "truncated")
    refute state["complete"]
  end

  def test_rejects_incomplete_or_cross_scope_snapshots
    assert_raises(Wrangle::DriverError) do
      Wrangle::DesktopObservation.new(scope: @scope, snapshot: {}, window: @window)
    end
    assert_raises(Wrangle::ScopeLost) do
      Wrangle::DesktopObservation.new(scope: @scope, snapshot: snapshot_with(tree),
                                      window: @window.merge("id" => "w-2"))
    end
    assert_raises(Wrangle::ScopeLost) do
      Wrangle::DesktopObservation.new(scope: @scope,
                                      snapshot: snapshot_with(tree).merge("window" => { "id" => "w-2" }),
                                      window: @window)
    end
  end

  private

  def tree(name = "Button")
    { "role" => "window", "children" => [{ "ref_id" => "@s:e1", "role" => "button", "name" => name }] }
  end

  def snapshot_with(tree, id: "s1")
    { "snapshot_id" => id, "complete" => true, "tree" => tree, "window" => { "id" => "w-1" } }
  end
end
