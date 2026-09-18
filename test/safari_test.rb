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
    assert_equal [false], verified["guard"] # freshness for both the fill and the click
  end

  # A fill has a target, so it is checked against that target. Falling back to the whole-page marker
  # compares the title, every word of text, and every action on the page, which rejects a decision
  # about a search box because a price updated somewhere else.
  def test_anything_aimed_at_an_element_is_checked_against_that_element
    session = dedicated
    page = session.observe
    session.act(find(page, "Destination"), page, text: "Lisbon")

    assert_equal(%w[install observe guard act], page_ops.map { _1["op"] })
  end

  # Scrolling has no target, so only the page as a whole can speak for it.
  def test_an_action_with_no_target_falls_back_to_the_page_marker
    session = dedicated
    page = session.observe
    session.act(find(page, "Scroll down"), page)

    assert_includes page_ops.map { _1["op"] }, "marker"
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

  # The ambiguity is real but it is the caller's to accept, and safaridriver leaves extra processes
  # behind whether or not anyone wanted them.
  def test_the_second_safari_process_can_be_accepted_deliberately
    session = track(Wrangle::Safari.new(url: FIXTURE_URL, display: 1, allow_multiple_safari: true,
                                        bridge: bridge(safari_instances: 2)))

    assert_equal FIXTURE_URL, session.observe["url"]
  end

  # A ping that says nothing about instances is not a ping that says there are two.
  def test_a_ping_without_an_instance_count_is_not_treated_as_a_conflict
    session = dedicated(safari_instances: nil)

    assert_equal FIXTURE_URL, session.observe["url"]
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

  # --- what moved ----------------------------------------------------------------------------

  # A run spends about a third of a second re-deciding every time a guard rejects one, so which part
  # of the guard moved is the difference between a fixable cost and a mystery. Before these were told
  # apart, a query string being rewritten and a document being replaced read as the same line.
  def test_a_stale_decision_says_which_part_of_the_guard_moved
    { "origin" => "The document was replaced", "route" => "The page navigated elsewhere",
      "view" => "The page scrolled or resized", "form" => "A field elsewhere on the page changed",
      "self" => "The target itself changed", "scope" => "The content around the target changed",
      "gone" => "The target is gone" }.each do |moved, reason|
      session = dedicated(guard_moved: moved)
      page = session.observe
      error = assert_raises(Wrangle::StalePage) { session.act(find(page, "Find stays"), page) }

      assert_equal "#{reason}. Observe again.", error.message
    end
  end

  # The parts are reported outermost first. A replaced document explains every other difference, and
  # naming an inner one would send whoever reads it looking at the wrong thing.
  def test_the_outermost_difference_is_the_one_reported
    session = dedicated(guard_moved: %w[self scope origin])
    page = session.observe
    error = assert_raises(Wrangle::StalePage) { session.act(find(page, "Find stays"), page) }

    assert_equal "The document was replaced. Observe again.", error.message
  end

  # A status nobody wrote a rule for is the one case where Wrangle cannot know whether the page was
  # touched. It refuses to guess, and the session is over rather than quietly wrong.
  def test_an_unrecognised_outcome_poisons_the_session_rather_than_being_guessed_at
    session = dedicated(act: "nonsense")
    page = session.observe

    error = assert_raises(Wrangle::DeliveryUnknown) { session.act(find(page, "Find stays"), page) }

    assert_match(/"confused"/, error.message)
    assert_raises(Wrangle::Error) { session.observe }
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

  # --- actions the page offers but Wrangle will not dispatch -----------------------------------

  # Every one of these is a real action on a real observation, so the "was it observed" gate lets it
  # through. They are refused because they cannot be carried out, and refusing beats dispatching a
  # select with no value and hoping the page picks something.
  def test_an_offered_action_that_cannot_be_carried_out_is_refused_not_attempted
    broken = [
      { "id" => "x1", "kind" => "select", "node" => 3, "label" => "Sort by", "value" => nil },
      { "id" => "x2", "kind" => "scroll", "delta" => 0, "label" => "Scroll nowhere" },
      { "id" => "x3", "kind" => "click", "node" => "two", "label" => "Unnumbered button" },
      { "id" => "x4", "kind" => "teleport", "node" => 2, "label" => "Go somewhere" }
    ]
    session = dedicated(extra_actions: broken)
    page = session.observe

    broken.each do |action|
      assert_raises(ArgumentError, "#{action["label"]} should not be dispatched") do
        session.act(find(page, action["label"]), page)
      end
    end
    assert_empty page_ops.select { |op| op["op"] == "act" }
  end

  def test_text_belongs_to_a_fill_and_to_nothing_else
    session = dedicated
    page = session.observe

    assert_raises(ArgumentError) { session.act(find(page, "Find stays"), page, text: "unwanted") }
    assert_raises(ArgumentError) { session.act(find(page, "Destination"), page, text: "") }
  end

  # --- waiting -------------------------------------------------------------------------------

  # Waiting is an action the model can choose, so it goes through the same gate as a click: it is
  # matched against the observation, and it reports back like anything else. It touches nothing.
  def test_waiting_is_an_action_and_changes_nothing
    session = dedicated
    page = session.observe

    result = session.act(find(page, "Wait for the page to update"), page)

    assert_equal "wait", result["executed"]
    assert_empty page_ops.select { |op| op["op"] == "act" }
    assert_equal page["marker"], session.observe["marker"]
  end

  # --- refusing when the page cannot answer ----------------------------------------------------

  # A page mid-load answers a freshness check with something that is not "ok". Reading that as
  # "nothing changed" would wave a decision through against a document that is not there yet.
  def test_a_page_that_cannot_answer_is_not_treated_as_unchanged
    guarded = dedicated(loading_on: "guard")
    page = guarded.observe

    assert_equal "The page is still loading", guarded.moved(page, find(page, "Find stays"))

    # Targetless actions ask the whole page instead, and it can be mid-load too.
    markered = dedicated(loading_on: "marker")
    other = markered.observe

    assert_equal "The page is still loading", markered.moved(other, find(other, "Wait for the page to update"))
  end

  def test_an_action_whose_target_was_never_numbered_is_refused
    session = dedicated
    page = session.observe

    assert_equal "The target was never observed", session.moved(page, { "kind" => "click", "node" => "seven" })
  end

  # Two different unreadable payloads, two different readings. A missing guard means the element it
  # described is not there any more, which is worth saying; a guard that is present but the wrong
  # shape is not something to interpret, so it counts as a change and the decision is retaken.
  def test_an_unreadable_guard_counts_as_a_change
    session = dedicated
    page = session.observe
    action = find(page, "Find stays")

    assert_equal "The target is gone", session.moved(page.merge("guards" => {}), action)
    assert_equal "The page changed", session.moved(page.merge("guards" => { "2" => "not a hash" }), action)
    assert_equal "The page changed", session.moved(page.merge("page_key" => "not a hash"), action)
  end

  def test_a_page_that_has_not_moved_is_fresh
    session = dedicated
    page = session.observe

    assert session.fresh?(page, find(page, "Find stays"))
    assert session.fresh?(page)
    assert_nil session.moved(page)
  end

  # --- the block form ------------------------------------------------------------------------

  # Scope is the safety boundary, and the block form is the version of it that cannot be forgotten.
  def test_a_block_gets_the_session_and_the_window_is_closed_after_it
    session = nil
    Wrangle::Safari.open(FIXTURE_URL, display: 1, bridge: bridge) do |opened|
      session = opened

      assert_equal FIXTURE_URL, opened.observe["url"]
    end

    assert traced("close").first["owned"], "the window it opened should have been closed"
    assert_raises(Wrangle::Error) { session.observe }
  end

  # An exception is exactly when a window is most likely to be left behind.
  def test_the_window_is_closed_even_when_the_block_raises
    session = nil
    assert_raises(RuntimeError) do
      Wrangle::Safari.open(FIXTURE_URL, display: 1, bridge: bridge) do |opened|
        session = opened
        raise "the caller fell over"
      end
    end

    assert traced("close").first["owned"], "an exception is when a window is most likely left behind"
    assert_raises(Wrangle::Error) { session.observe }
  end

  def test_attach_without_a_block_returns_the_session
    windows = [{ url: FIXTURE_URL, window_id: 4242, tabs: 5 }]
    session = track(Wrangle::Safari.attach(window_id: 4242, url: FIXTURE_URL, bridge: bridge(windows: windows)))

    assert_equal "attach", session.mode
    assert_equal 4242, session.window_id
    assert_empty traced("close")
  end

  def test_without_a_block_the_session_is_returned_and_left_open
    session = track(Wrangle::Safari.open(FIXTURE_URL, display: 1, bridge: bridge))

    assert_equal "dedicated", session.mode
    assert_equal FIXTURE_URL, session.observe["url"]
    assert_empty traced("close")
  end

  def test_attach_takes_a_block_too_and_hands_back_a_window_it_does_not_own
    windows = [{ url: FIXTURE_URL, window_id: 4242, tabs: 5 }]
    handled = nil
    Wrangle::Safari.attach(window_id: 4242, url: FIXTURE_URL, bridge: bridge(windows: windows)) do |session|
      handled = session

      assert_equal "attach", session.mode
      assert_equal 4242, session.window_id
    end

    # Handed back, not closed: it was never Wrangle's window to close.
    assert_empty traced("close")
    assert_raises(Wrangle::Error) { handled.observe }
  end

  # --- observations the page cannot make -------------------------------------------------------

  # Every field is load-bearing somewhere downstream. A snapshot missing one parses perfectly well
  # and then fails much further away, so it is refused here.
  def test_a_snapshot_missing_a_promised_key_is_not_an_observation
    session = dedicated(incomplete_state: true)

    error = assert_raises(Wrangle::BridgeError) { session.observe }

    assert_match(/incomplete observation/, error.message)
  end

  # A document that will not take the binding is a document that cannot be worked on. The loop gives
  # up at its deadline rather than spinning against a page that will never answer.
  def test_a_document_that_will_not_bind_gives_up_instead_of_spinning
    session = dedicated(install_fails: true)

    assert_raises(Wrangle::StalePage) { session.observe }
  end

  # --- what a targetless action is checked against ---------------------------------------------

  def test_a_targetless_action_notices_the_whole_page_moving
    session = dedicated
    page = session.observe
    session.act(find(page, "Find stays"), page) # Anything at all, so the marker moves.

    assert_equal "The page changed", session.moved(page, find(page, "Wait for the page to update"))
    assert_equal "The page changed", session.moved(page)
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
