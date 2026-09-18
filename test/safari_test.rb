# frozen_string_literal: true

require "test_helper"

class SafariTest < Minitest::Test
  include BridgeHelpers

  # --- scope ---------------------------------------------------------------------------------

  def test_a_dedicated_window_is_opened_observed_and_closed
    session = dedicated
    page = session.observe

    assert_equal "dedicated", session.mode
    assert_predicate session, :owned?
    assert_equal FIXTURE_URL, page["url"]
    assert_equal 64, page["fingerprint"].length
    assert_equal 1, traced("open").first["display"]

    session.close
    assert traced("close").first["owned"]
  end

  def test_reads_are_cheap_but_binding_and_mutating_are_verified
    session = dedicated
    page = session.observe
    session.act(find(page, "Destination"), page, text: "Lisbon")
    page = session.observe
    session.act(find(page, "Find stays"), page)

    verified = traced("eval").group_by { |r| JSON.parse(r["payload"])["op"] }
                             .transform_values { |rs| rs.map { |r| r["verify"] }.uniq }
    assert_equal [true], verified["install"]
    assert_equal [true], verified["act"]
    assert_equal [false], verified["observe"]
    assert_equal [false], verified["marker"] # freshness for a fill
    assert_equal [false], verified["guard"]  # freshness for a click
  end

  def test_an_attached_window_is_never_closed_and_is_pinned_to_its_url
    session = handed_over
    session.observe

    refute_predicate session, :owned?
    scopes = traced("eval").map { |request| request["scope"] }
    assert(scopes.all? { |scope| scope["url"] == FIXTURE_URL })
    assert(scopes.all? { |scope| scope["tab_index"] == 1 })

    session.close
    assert_empty traced("close")
  end

  def test_a_second_safari_process_stops_the_session_before_any_window_is_touched
    error = assert_raises(Wrangle::Error) { dedicated(safari_instances: 2) }
    assert_match(/ambiguous/, error.message)
    assert_empty traced("open")
  end

  def test_a_scope_change_ends_the_session_rather_than_finding_another_window
    # The window this session opened gains a tab: the user has reclaimed it, so the session stops.
    session = dedicated(grow_tabs_after: 2)
    session.observe

    error = assert_raises(Wrangle::ScopeLost) { session.observe }
    assert_match(/2 tabs/, error.message)
    assert_raises(Wrangle::ScopeLost) { session.observe }
    assert_raises(Wrangle::ScopeLost) { session.act({ "id" => "a3" }, { "actions" => [] }) }

    session.close # Refusing to close a window that is no longer exclusively ours is not an error.
    assert traced("close").first["owned"]
  end

  def test_a_replaced_document_is_refused_in_a_handed_over_tab
    session = handed_over(forget_epoch_after: 1)
    session.observe
    error = assert_raises(Wrangle::ScopeLost) { session.observe }
    assert_match(/replaced its document/, error.message)
  end

  def test_a_replaced_document_is_rebound_in_a_window_we_opened
    session = dedicated(forget_epoch_after: 1)
    session.observe
    assert_equal FIXTURE_URL, session.observe["url"]
  end

  def test_a_closed_session_refuses_everything
    session = dedicated
    session.close
    error = assert_raises(Wrangle::Error) { session.observe }
    assert_match(/closed/, error.message)
  end

  # --- actions -------------------------------------------------------------------------------

  def test_only_an_observed_action_with_matching_inputs_is_executed
    session = dedicated
    page = session.observe

    # Not the observed candidate: a hand-built action with the same id is still refused.
    assert_raises(ArgumentError) do
      session.act({ "id" => "a1", "kind" => "fill", "node" => 1, "label" => "Destination" }, page, text: "x")
    end
    assert_raises(ArgumentError) { session.act(find(page, "Destination"), page) }
    assert_raises(ArgumentError) { session.act(find(page, "Destination"), page, text: "x" * 2001) }
    assert_raises(ArgumentError) { session.act(find(page, "Find stays"), page, text: "unwanted") }
    assert_empty(page_ops.select { |op| op["op"] == "act" })
  end

  def test_each_action_kind_reaches_the_page_and_changes_it
    session = dedicated
    page = session.observe
    [["Destination", "Lisbon"], ["Category → Design", nil], ["Find stays", nil]].each do |label, text|
      assert session.act(find(page, label), page, text: text)["executed"]
      page = session.observe
    end
    assert_includes page["text"], "1 places in Lisbon"
  end

  def test_a_stale_decision_is_refused_before_anything_is_dispatched
    session = dedicated
    page = session.observe
    session.act(find(page, "Destination"), page, text: "Lisbon")

    assert_raises(Wrangle::StalePage) { session.act(find(page, "Destination"), page, text: "Porto") }
    assert_equal(1, page_ops.count { |op| op["op"] == "act" })
  end

  def test_a_blocked_target_asks_for_a_new_observation
    session = dedicated(act: "blocked")
    page = session.observe
    assert_raises(Wrangle::StalePage) { session.act(find(page, "Find stays"), page) }
  end

  # --- delivery ------------------------------------------------------------------------------

  def test_an_unconfirmed_action_poisons_the_session
    session = dedicated(act: "unconfirmed")
    page = session.observe

    assert_raises(Wrangle::DeliveryUnknown) { session.act(find(page, "Find stays"), page) }
    assert_raises(Wrangle::DeliveryUnknown) { session.observe }

    session.close
    # A session that may have mutated the page does not close the window it cannot describe.
    assert_empty traced("close")
  end

  def test_a_silent_action_is_resolved_by_reading_its_nonce_never_by_repeating_it
    session = dedicated(act: "finished_then_silent")
    page = session.observe

    assert_equal "a3", session.act(find(page, "Find stays"), page)["executed"]
    assert_equal(1, page_ops.count { |op| op["op"] == "act" })
    assert_equal(1, page_ops.count { |op| op["op"] == "probe" })
  end

  def test_an_action_that_only_started_is_reported_as_unknown
    session = dedicated(act: "started_then_silent")
    page = session.observe
    error = assert_raises(Wrangle::DeliveryUnknown) { session.act(find(page, "Find stays"), page) }
    assert_match(/without confirming/, error.message)
  end

  def test_an_action_the_page_never_recorded_is_reported_as_not_executed
    session = dedicated(act: "forgotten_then_silent")
    page = session.observe

    error = assert_raises(Wrangle::Error) { session.act(find(page, "Find stays"), page) }
    assert_match(/never executed/, error.message)
    assert_equal FIXTURE_URL, session.observe["url"] # Nothing landed, so the session stays usable.
  end

  # --- construction --------------------------------------------------------------------------

  def test_construction_arguments_are_validated_before_a_bridge_is_started
    assert_raises(ArgumentError) { Wrangle::Safari.new(url: "  ") }
    assert_raises(ArgumentError) { Wrangle::Safari.new(window_id: "26081") }
    assert_raises(ArgumentError) { Wrangle::Safari.new(url: FIXTURE_URL, display: 1, bounds: [0, 0, 10, 10]) }
    assert_raises(ArgumentError) { Wrangle::Safari.new(url: FIXTURE_URL, display: -1) }
    assert_raises(ArgumentError) { Wrangle::Safari.new(url: FIXTURE_URL, bounds: [0, 0, 10]) }
  end
end
