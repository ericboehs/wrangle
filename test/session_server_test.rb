# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/scripted_jev"

# The interactive layer exists so an agent can notice it was wrong and course-correct. These tests
# are about that: does a reply say what changed, and does a refusal say what to do about itself.
class SessionServerTest < Minitest::Test
  include BridgeHelpers

  def setup
    super
    @socket = File.join(@tmpdir, "test.sock")
  end

  def teardown
    stop_server
    super
  end

  def serving(**config)
    session = dedicated(**config)
    server = Wrangle::SessionServer.new(@socket, {}, session: session)
    @thread = Thread.new { server.run }
    @thread.abort_on_exception = false
    client = Wrangle::SessionClient.new(@socket)
    sleep 0.02 until File.socket?(@socket)
    client
  end

  def stop_server
    @thread&.kill
    @thread = nil
  end

  # The seam the run loop drives, without the socket in the way. `decide` watches the page while Jev
  # thinks and keeps the read; `observe!` may promote it, but only while it still describes the page.
  def seam(turns, thinks_for: 0.2, **config)
    Wrangle::SessionServer.new(@socket, {}, session: dedicated(**config),
                                            jev: ScriptedJev.new(turns, thinks_for: thinks_for))
  end

  def reads = page_ops.count { _1["op"] == "observe" }

  def test_a_rejected_decision_reuses_the_read_taken_while_jev_was_thinking
    server = seam([{ operation: "CLICK", target: "Find stays", confidence: 0.9 }])
    server.decide({ "goal" => "Press it" })
    taken = reads
    server.observe!

    assert_equal taken, reads
  end

  # The one way the watch could report the wrong thing: a read from before an action outliving the
  # page it was taken from. It is stamped with the action count, so after a mutation it is dropped.
  def test_a_read_taken_before_an_action_is_never_promoted_after_it
    server = seam([{ operation: "CLICK", target: "Find stays", confidence: 0.9 }])
    step = server.decide({ "goal" => "Press it" })
    server.perform(step.fetch("choice"), nil)
    taken = reads
    server.observe!

    assert_equal taken + 1, reads
    assert_match(/1 places/, server.page["text"])
  end

  def test_status_describes_the_window_without_observing_it
    value = serving.call("status").fetch("value")
    assert_equal "dedicated", value["mode"]
    assert value["owned"]
    assert_equal 0, value["actions_taken"]
    refute value["observed"]
  end

  def test_the_first_observation_numbers_every_action_and_has_nothing_to_compare
    value = serving.call("observe").fetch("value")
    assert_equal BridgeHelpers::FIXTURE_URL, value["url"]
    assert_nil value["changed"]
    assert_equal([1, 2, 3, 4, 5], value["actions"].map { |a| a["ref"] })
    assert_equal "Destination", value["actions"].first["label"]
    assert_equal 12, value["fingerprint"].length
  end

  def test_an_action_reports_what_moved_on_the_page
    client = serving
    client.call("observe")
    value = client.call("act", ref: 1, text: "Lisbon", settle: 0).fetch("value")

    assert_equal "Destination", value["executed"]
    assert_equal "fill", value["kind"]
    refute value["changed"]["same_page"]
    assert_operator value["changed"]["text_delta"], :>, 0
    assert_equal 1, client.call("status").dig("value", "actions_taken")
  end

  def test_an_unchanged_page_reports_that_nothing_moved
    client = serving
    client.call("observe")
    before = client.call("observe").fetch("value")
    after = client.call("observe").fetch("value")

    assert_equal before["fingerprint"], after["fingerprint"]
    assert after["changed"]["same_page"], "an unchanged page must report same_page"
    assert_empty after["changed"]["appeared"]
    assert_equal 0, after["changed"]["text_delta"]
  end

  # A click that navigates changes nothing for the first few hundred milliseconds. Settling must not
  # mistake that lag for a finished page, or it reports a working action as "nothing changed".
  def test_settling_watches_a_still_page_past_the_quiet_floor
    client = serving
    client.call("observe")
    elapsed = timed { client.call("observe", settle: 3) }

    assert_operator elapsed, :>=, Wrangle::SessionServer::QUIET_FLOOR - 0.2
    assert_operator elapsed, :<, 3.5, "it must still stop at the timeout"
  end

  def test_no_settle_returns_immediately
    client = serving
    client.call("observe")
    assert_operator timed { client.call("observe", settle: 0) }, :<, 0.5
  end

  def timed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  def test_scrolling_reports_how_far_the_page_moved
    client = serving
    first = client.call("observe").fetch("value")
    scroll = first["actions"].find { |a| a["kind"] == "scroll" }
    value = client.call("act", ref: scroll["ref"], settle: 0).fetch("value")

    assert_equal 400, value["changed"]["scroll_delta"]
    assert_equal 400, value["scroll"]["y"]
    assert_equal 2400, value["scroll"]["height"]
  end

  def test_a_stale_reference_is_refused_with_a_recoverable_hint
    client = serving
    client.call("observe")
    reply = client.call("act", ref: 99)

    refute reply["ok"]
    assert_equal "ArgumentError", reply["class"]
    assert_match(/offered 5/, reply["error"])
    refute reply["terminal"]
    assert reply["retryable"]
    assert_match(/observe/i, reply["hint"])
  end

  def test_acting_before_observing_is_refused
    reply = serving.call("act", ref: 1)
    assert_equal "ArgumentError", reply["class"]
    assert_match(/Observe before acting/, reply["error"])
  end

  def test_a_lost_scope_is_reported_as_terminal
    client = serving(grow_tabs_after: 2)
    client.call("observe")
    reply = client.call("observe")

    refute reply["ok"]
    assert_equal "ScopeLost", reply["class"]
    assert reply["terminal"], "a lost scope ends the session"
    refute reply["retryable"]
    assert_match(/cannot continue/i, reply["hint"])
  end

  def test_an_unconfirmed_action_is_terminal_and_never_repeated
    client = serving(act: "unconfirmed")
    client.call("observe")
    reply = client.call("act", ref: 1, text: "Lisbon", settle: 0)

    assert_equal "DeliveryUnknown", reply["class"]
    assert reply["terminal"]
    assert_equal(1, page_ops.count { |op| op["op"] == "act" })
  end

  # Text read off a cached observation reports the page as it was before the last navigation
  # finished, so it is always read fresh — and a settle applies to it the same way it does to a look.
  def test_text_can_be_settled_for_like_an_observation
    client = serving
    client.call("observe")

    assert_includes client.call("text", settle: 1).dig("value", "text"), "slow down"
  end

  # --- settling on a page that is actually moving ------------------------------------------------

  # The quiet floor exists because two identical reads can arrive before the browser has begun. A
  # page that genuinely moves and then stops should be waited out and then reported as having moved.
  def test_a_page_that_moves_and_then_stops_is_waited_out_and_reported_as_changed
    client = serving(drifts: 3)
    client.call("observe")

    value = client.call("observe", settle: 5).fetch("value")

    assert value["changed"], "the page moved, so the reply should say so"
  end

  # Waiting for quiet is a proxy. Waiting for the thing you need is the real test, and a results list
  # may never go quiet at all — so being told what to look for ends the wait as soon as it appears.
  def test_being_told_what_to_look_for_stops_the_wait_as_soon_as_it_appears
    client = serving(drifts: 40)
    client.call("observe")

    elapsed = timed { client.call("act", ref: 1, text: "Lisbon", settle: 10, expect: "Lisbon") }

    assert_operator elapsed, :<, Wrangle::SessionServer::QUIET_FLOOR,
                    "it should not sit out the quiet floor once the text is on the page"
  end

  # The opposite case: told to wait for something that never comes, it waits out its timeout rather
  # than returning the moment the page happens to hold still.
  def test_waiting_for_something_that_never_arrives_waits_out_the_timeout
    client = serving(drifts: 500) # Enough that the page is still moving when the deadline arrives.
    client.call("observe")

    elapsed = timed { client.call("act", ref: 1, text: "Lisbon", settle: 2, expect: "never appears") }

    assert_operator elapsed, :>=, 2
  end

  # --- a run with nothing in it ------------------------------------------------------------------

  # A run with no budget does no work and stops at nothing. Every summary field that describes "the
  # last step" has to cope with there being no last step, and a run refusing to start is the ordinary
  # way that happens — `--steps 0` is a reasonable thing for a caller to pass.
  def test_a_run_with_no_budget_summarises_cleanly_instead_of_failing
    jev = ScriptedJev.new([])
    server = Wrangle::SessionServer.new(@socket, {}, session: dedicated, jev: jev)
    @thread = Thread.new { server.run }
    sleep 0.02 until File.socket?(@socket)
    client = Wrangle::SessionClient.new(@socket)

    value = client.call("run", goal: "Nothing to do", plan: ["A leg"], execute: true,
                               settle: 0, steps: 0).fetch("value")

    assert_empty value["steps"]
    assert_nil value["stopped"]
    assert_equal 1, value["legs"]
    assert_empty jev.asked, "no budget means nothing was asked of the model"
  end

  def test_an_op_the_server_does_not_have_is_refused_by_name
    reply = serving.call("teleport")

    refute reply["ok"]
    assert_match(/Unknown op "teleport"/, reply["error"])
  end

  # A settle that is told what to look for and gets it on the second read, not the first: the text
  # arrives while the page is still moving, which is the case the whole mechanism exists for.
  def test_text_that_arrives_mid_settle_ends_the_settle
    client = serving(drifts: 500, appears_after: 2, appears: "Gate B12")
    client.call("observe")

    value = client.call("act", ref: 1, text: "Lisbon", settle: 10, expect: "Gate B12").fetch("value")

    assert value["changed"]
  end

  # Watching stops at the first pair of reads that agree, because there is nothing further to learn
  # from a page that has held still. A page that has not held still is read again for as long as the
  # answer takes — which is the only case where the second read is worth the Apple Events.
  def test_a_page_that_keeps_moving_is_read_again_for_as_long_as_the_answer_takes
    # A full second of thinking against a 50ms poll. The margin is deliberate: each read is a
    # subprocess round-trip, and on a slow machine a tighter budget measures the runner, not the loop.
    server = seam([{ operation: "CLICK", target: "Find stays", confidence: 0.9 }],
                  thinks_for: 1.0, drifts: 500)
    server.observe!

    before = reads
    server.decide({ "goal" => "Press it" })

    assert_operator reads - before, :>, 2, "a moving page should be looked at more than twice"
  end

  # The run loop reaches `decide` in process; the CLI reaches it over the socket. They are the same
  # decision, and the socket is the path a caller stepping through a page by hand actually takes.
  def test_a_decision_can_be_asked_for_over_the_socket
    session = dedicated
    server = Wrangle::SessionServer.new(@socket, {}, session: session,
                                                     jev: ScriptedJev.new([{ operation: "CLICK",
                                                                             target: "Find stays",
                                                                             confidence: 0.9 }]))
    @thread = Thread.new { server.run }
    sleep 0.02 until File.socket?(@socket)
    client = Wrangle::SessionClient.new(@socket)
    client.call("observe")

    value = client.call("decide", goal: "Press it").fetch("value")

    assert_equal "CLICK", value["operation"]
    assert_equal "Find stays", value["action"]
    refute value["executed"], "deciding is not doing"
  end

  # A poisoned session refuses to close its window, and that refusal is correct — but it must not
  # take the server down with it or leave the socket behind for the next caller to trip over.
  def test_a_session_that_refuses_to_close_still_lets_the_server_leave
    client = serving(close_fails: true)
    client.call("observe")

    client.call("close")
    @thread.join(2)

    refute_path_exists @socket
  end

  def test_closing_is_a_reply_before_it_is_a_shutdown
    client = serving

    assert_equal({ "closing" => true }, client.call("close").fetch("value"))
  end

  # Closing takes the socket with it: a stale socket file is a session that looks alive and is not.
  def test_closing_takes_the_socket_with_it
    client = serving
    client.call("close")

    @thread.join(2)

    refute_path_exists @socket
  end

  # --- the client side ---------------------------------------------------------------------------

  def test_a_server_that_hangs_up_without_replying_is_reported_not_silently_nil
    listener = UNIXServer.new(@socket)
    # Reads the request before hanging up. Closing without reading is a different failure — the write
    # itself gets EPIPE — and both have to end the same way, so the second case follows.
    Thread.new { listener.accept.then { |c| c.gets and c.close } }

    error = assert_raises(Wrangle::BridgeError) { Wrangle::SessionClient.new(@socket).call("status") }

    assert_match(/closed without replying/, error.message)
  ensure
    listener&.close
  end

  # The session was there when the connection opened and gone before the request was even read. A
  # caller should not have to know the difference between that and a reply that never came.
  def test_a_session_that_dies_before_reading_the_request_is_reported_the_same_way
    listener = UNIXServer.new(@socket)
    Thread.new { listener.accept.close }

    error = assert_raises(Wrangle::BridgeError) do
      10.times { Wrangle::SessionClient.new(@socket).call("status") }
    end

    assert_match(/closed without replying/, error.message)
  ensure
    listener&.close
  end

  def test_running_is_false_for_a_socket_with_nothing_behind_it
    refute_predicate Wrangle::SessionClient.new(File.join(@tmpdir, "nothing.sock")), :running?
  end

  # A socket file is not a session. Something has to be listening, and it has to answer.
  def test_running_is_false_for_a_socket_that_does_not_answer
    listener = UNIXServer.new(@socket)
    accepting = Thread.new { loop { listener.accept.close } }
    accepting.report_on_exception = false # It is killed by the ensure below; that is not news.

    refute_predicate Wrangle::SessionClient.new(@socket), :running?
  ensure
    listener&.close
  end

  def test_running_is_true_once_a_server_answers
    serving

    assert_predicate Wrangle::SessionClient.new(@socket), :running?
  end

  # --- when the server itself is wrong -------------------------------------------------------------

  # A bug is still a reply. The client is blocked on a socket read, so a server that dies here hangs
  # the caller forever instead of telling it anything.
  def test_a_bug_in_the_server_is_reported_instead_of_hanging_the_caller
    session = dedicated
    session.define_singleton_method(:observe) { raise NoMethodError, "undefined method 'fetch' for nil" }
    server = Wrangle::SessionServer.new(@socket, {}, session: session)
    @thread = Thread.new { server.run }
    sleep 0.02 until File.socket?(@socket)

    reply = Wrangle::SessionClient.new(@socket).call("observe")

    refute reply["ok"]
    assert_equal "NoMethodError", reply["class"]
    assert_match(/internal error/, reply["error"])
    assert reply["terminal"], "the session is suspect after a bug, so it does not pretend otherwise"
  end

  # --- the options the server is started with --------------------------------------------------

  # The MCP backend drives its own automation tab, so there is no window of yours for it to take
  # over. Saying so beats opening something the caller did not ask for.
  def test_attaching_with_the_mcp_backend_is_refused_before_anything_is_started
    server = Wrangle::SessionServer.new(@socket, { "backend" => "mcp", "window_id" => 4242 })

    error = assert_raises(ArgumentError) { server.send(:start_session) }

    assert_match(/cannot attach/, error.message)
  end

  def test_the_backend_is_reported_as_the_one_that_was_asked_for
    session = dedicated
    server = Wrangle::SessionServer.new(@socket, { "backend" => "mcp" }, session: session)
    @thread = Thread.new { server.run }
    sleep 0.02 until File.socket?(@socket)

    assert_equal "mcp", Wrangle::SessionClient.new(@socket).call("status").dig("value", "backend")
  end

  def test_the_socket_path_follows_the_home_the_caller_set
    original = ENV.fetch("WRANGLE_HOME", nil)
    ENV["WRANGLE_HOME"] = "/tmp/wrangle-home-test"

    assert_equal "/tmp/wrangle-home-test/work.sock", Wrangle::SessionServer.socket_path("work")
  ensure
    ENV["WRANGLE_HOME"] = original
  end

  # --- the protocol itself -----------------------------------------------------------------------

  # A connection that opens and says nothing is a port scan, a dropped client, or a health check.
  # The server closes it and carries on; anything else lets a stray connection end the session.
  def test_a_connection_that_says_nothing_is_dropped_without_ending_the_session
    client = serving
    UNIXSocket.new(@socket).close

    assert_equal "dedicated", client.call("status").dig("value", "mode")
  end

  def test_a_line_that_is_not_json_is_refused_without_ending_the_session
    client = serving
    socket = UNIXSocket.new(@socket)
    socket.puts("this is not json")
    reply = JSON.parse(socket.gets)
    socket.close

    refute reply["ok"]
    assert_equal "dedicated", client.call("status").dig("value", "mode")
  end

  def test_text_is_returned_whole_for_the_caller_to_filter
    client = serving
    client.call("observe")
    assert_includes client.call("text").dig("value", "text"), "slow down"
  end

  def test_an_unknown_op_is_refused_rather_than_guessed
    reply = serving.call("teleport")
    assert_equal "ArgumentError", reply["class"]
    assert_match(/Unknown op/, reply["error"])
  end

  def test_close_ends_the_session_and_removes_the_socket
    client = serving
    assert client.call("close").dig("value", "closing")
    @thread.join(3)
    refute File.socket?(@socket), "the socket must not outlive the session"
  end

  def test_a_missing_session_is_a_clear_bridge_error
    client = Wrangle::SessionClient.new(File.join(@tmpdir, "absent.sock"))
    refute_predicate client, :running?
    error = assert_raises(Wrangle::BridgeError) { client.call("status") }
    assert_match(/No wrangle session/, error.message)
  end
end
