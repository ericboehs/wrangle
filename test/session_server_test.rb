# frozen_string_literal: true

require "test_helper"

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
    assert_equal([1, 2, 3, 4], value["actions"].map { |a| a["ref"] })
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
    assert_match(/offered 4/, reply["error"])
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
