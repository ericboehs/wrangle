# frozen_string_literal: true

require "test_helper"

class JxaBridgeTest < Minitest::Test
  include BridgeHelpers

  def test_start_pings_then_installs_both_scripts_once
    active = bridge
    ping = active.start
    assert ping["safari_running"]
    installed = traced("scripts")
    assert_equal 1, installed.size
    assert_includes installed.first["page"], "__wrangle"
    assert_operator installed.first["snapshot"].bytesize, :>, 1000
  ensure
    active&.close
  end

  def test_ping_reports_how_many_safari_processes_are_running
    active = bridge(safari_instances: 3)
    assert_equal 3, active.start["safari_instances"]
  ensure
    active&.close
  end

  def test_a_silent_bridge_times_out_instead_of_waiting_forever
    active = started(hang_on: "displays")
    assert_raises(Wrangle::BridgeTimeout) { active.request("displays", timeout: 0.3) }
  ensure
    active&.close
  end

  def test_invalid_json_is_a_bridge_error
    active = started(garbage_on: "displays")
    error = assert_raises(Wrangle::BridgeError) { active.request("displays") }
    assert_match(/invalid JSON/, error.message)
  ensure
    active&.close
  end

  def test_a_dead_process_is_a_bridge_error
    active = started(die_on: "displays")
    error = assert_raises(Wrangle::BridgeError) { active.request("displays") }
    assert_match(/exited/, error.message)
  ensure
    active&.close
  end

  def test_a_refusal_carries_its_code
    active = started
    error = assert_raises(Wrangle::BridgeCallError) { active.request("close", window_id: 1, owned: false) }
    assert_equal "bad_request", error.code
    refute_predicate error, :scope?
  ensure
    active&.close
  end

  def test_a_late_reply_to_an_abandoned_request_is_discarded
    active = started(stale_reply_on: "displays")
    assert_equal 2, active.request("displays").fetch("displays").size
  ensure
    active&.close
  end

  def test_closing_twice_is_safe_and_stops_the_process
    active = started
    pid = active.pid
    active.close
    active.close
    refute active.running?
    assert_raises(Wrangle::BridgeError) { active.request("displays") }
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end

  def test_a_missing_script_and_bad_timeouts_are_refused
    assert_raises(ArgumentError) { Wrangle::JxaBridge.new(request_timeout: 0) }
    error = assert_raises(Wrangle::BridgeError) { Wrangle::JxaBridge.new(script: "/nonexistent/bridge.js").start }
    assert_match(/missing/, error.message)
  end

  def test_starting_twice_is_refused
    active = started
    assert_raises(Wrangle::BridgeError) { active.start }
  ensure
    active&.close
  end

  def test_evaluation_requires_a_scope_and_a_request
    active = started
    assert_raises(ArgumentError) { active.evaluate("not a scope", { "op" => "observe" }) }
    assert_raises(ArgumentError) { active.payload({ "text" => "no op" }) }
  ensure
    active&.close
  end

  # --- what a page can hand back ---------------------------------------------------------------

  # The page's reply crosses two encodings and a process boundary, so "it parsed" is not the same as
  # "it is a result". Each of these is a different way for a broken script to look like an answer.
  def test_a_page_result_that_is_not_a_usable_result_is_refused
    { "missing" => /no page result/, "unparsable" => /invalid JSON/,
      "wrong_shape" => /invalid result/, "statusless" => /invalid result/ }.each do |mode, message|
      active = started(page_result: mode)
      window = active.request("open", url: BridgeHelpers::FIXTURE_URL)
      active.request("scripts", page: "// page", snapshot: "// snapshot")
      scope = { "window_id" => window["window_id"], "tab_index" => 1 }

      error = assert_raises(Wrangle::BridgeError) { active.evaluate(scope, { "op" => "observe" }) }

      assert_match(message, error.message, "page_result: #{mode}")
      active.close
    end
  end

  # --- lines the bridge should not accept ---------------------------------------------------

  # A page big enough to blow the line limit is a page that cannot be trusted to have arrived whole.
  def test_an_oversized_line_is_refused_rather_than_held
    active = started(oversized_on: "windows")

    error = assert_raises(Wrangle::BridgeError) { active.request("windows") }

    assert_match(/oversized/, error.message)
  end

  def test_a_reply_that_is_not_an_object_is_refused
    active = started(nonobject_on: "windows")

    error = assert_raises(Wrangle::BridgeError) { active.request("windows") }

    assert_match(/non-object/, error.message)
  end

  # --- the closed and unstarted states --------------------------------------------------------

  def test_a_bridge_that_was_never_started_refuses_work_and_is_not_running
    idle = bridge

    refute_predicate idle, :running?
    error = assert_raises(Wrangle::BridgeError) { idle.request("windows") }

    assert_match(/not started/, error.message)
  end

  def test_a_closed_bridge_refuses_work
    active = started
    active.close

    refute_predicate active, :running?
    error = assert_raises(Wrangle::BridgeError) { active.request("windows") }

    assert_match(/closed/, error.message)
  end

  # A bridge that will not leave when asked is made to. The fake ignores the exit request entirely,
  # so close has to fall through to signalling the process.
  def test_a_bridge_that_ignores_its_exit_request_is_terminated
    active = started(hang_on: "exit")
    pid = active.request("ping")["pid"]

    active.close

    refute_predicate active, :running?
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end

  # Anything Safari writes to stderr is kept, because it is the only explanation available when a
  # bridge dies without answering.
  def test_what_the_bridge_writes_to_stderr_is_kept_for_the_error_that_follows
    active = started(stderr_on: "windows", die_on: "windows")

    assert_raises(Wrangle::BridgeError) { active.request("windows") }

    assert_includes active.stderr.join, "osascript: something went wrong"
  end

  # Only the tail of what the bridge said is kept. A bridge that chatters cannot be allowed to grow
  # an unbounded transcript in memory, and the last thing it said is the part that explains the death.
  def test_only_the_tail_of_a_chattering_bridge_is_kept
    active = started(stderr_on: "windows", stderr_flood: 120, die_on: "windows")

    assert_raises(Wrangle::BridgeError) { active.request("windows") }

    assert_operator active.stderr.length, :<=, Wrangle::JxaBridge::STDERR_LINES
    refute_includes active.stderr.join, "noise 0\n", "the oldest lines should have been dropped"
    assert_includes active.stderr.join, "noise 119", "the newest should not have been"
  end

  # A reply to a request that has already timed out is not this request's reply, however well-formed
  # it is. Mistaking one for the other would answer a question with the answer to an earlier one.
  def test_a_late_reply_to_an_abandoned_request_is_discarded_not_mistaken_for_this_one
    active = started(late_reply_on: "windows")

    reply = active.request("windows")

    refute reply["late"], "the abandoned request's reply must not be handed back as this one's"
    assert reply.key?("windows"), "the real reply is the one with the answer in it"
  end

  # An id nobody asked for cannot be discarded as stale the way a late one can, and using it would
  # answer a question that was never put. The bridge is not trustworthy after this.
  def test_a_reply_under_an_id_nobody_asked_for_is_refused
    active = started(wrong_id_on: "windows")

    error = assert_raises(Wrangle::BridgeError) { active.request("windows") }

    assert_match(/unexpected response id/, error.message)
  end

  # A request that gets no answer at all inside its timeout is a timeout, not a hang.
  def test_a_request_that_is_never_answered_times_out
    active = started(hang_on: "windows")

    assert_raises(Wrangle::BridgeTimeout) { active.request("windows", timeout: 0.3) }
  end

  # Once the process behind it has been reaped, every later request says so up front, with its exit
  # status, instead of discovering it again by writing into a pipe with nothing on the other end.
  def test_a_bridge_whose_process_has_been_reaped_says_so_up_front
    active = started(die_on: "windows")
    assert_raises(Wrangle::BridgeError) { active.request("windows") }
    sleep 0.05 while active.running? # The waiter thread reaps on its own schedule, not ours.

    error = assert_raises(Wrangle::BridgeError) { active.request("ping") }

    assert_match(/exited with status/, error.message)
  end

  def test_closing_a_bridge_that_was_never_started_is_not_an_error
    idle = bridge
    idle.close

    assert_raises(Wrangle::BridgeError) { idle.request("windows") }
  end

  def test_window_and_display_listings_use_a_supplied_bridge
    active = started(windows: [{ url: BridgeHelpers::FIXTURE_URL, window_id: 77 }])
    assert_equal 1920, Wrangle::Safari.displays(bridge: active)[1]["width"]
    listed = Wrangle::Safari.windows(bridge: active)
    assert_equal [{ "window_id" => 77, "tabs" => 1, "tab_index" => 1, "bounds" => [0, 0, 1200, 800],
                    "display" => 0 }], listed
    # Titles and URLs identify a tab to its owner, so they are never reported unless asked for.
    assert_equal BridgeHelpers::FIXTURE_URL, Wrangle::Safari.windows(titles: true, bridge: active).first["url"]
  ensure
    active&.close
  end
end
