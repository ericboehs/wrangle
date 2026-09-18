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
