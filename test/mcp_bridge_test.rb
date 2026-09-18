# frozen_string_literal: true

require "test_helper"

# The MCP bridge is a transport, so these tests are about the pipe rather than the page: the
# handshake, unwrapping a tool reply, and what happens when the server on the other end misbehaves.
# It runs against a fake `safaridriver --mcp` speaking real JSON-RPC over a real pipe, because the
# failures worth testing here — a silent server, a closed pipe, junk instead of JSON — only exist at
# that boundary.
#
# The one rule with teeth is the last group: a mutation whose runtime vanished is never re-sent.
class McpBridgeTest < Minitest::Test
  FAKE = File.expand_path("fixtures/fake_mcp.rb", __dir__)

  def setup
    super
    @tmpdir = Dir.mktmpdir("wrangle-mcp")
    @trace = File.join(@tmpdir, "rpc.jsonl")
    @bridges = []
  end

  def teardown
    @bridges.each(&:close)
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
    super
  end

  def bridge(request_timeout: 5, startup_timeout: 10, **config)
    path = File.join(@tmpdir, "config-#{@bridges.length}.json")
    File.write(path, JSON.generate(config.merge(trace: @trace)))
    made = Wrangle::McpBridge.new(command: [RbConfig.ruby, FAKE, path],
                                  request_timeout: request_timeout, startup_timeout: startup_timeout)
    @bridges << made
    made
  end

  def opened(**config)
    bridge(**config).tap do |made|
      made.start
      made.request("open", url: "https://fixture.test/stays")
    end
  end

  def rpc_calls = File.exist?(@trace) ? File.readlines(@trace).map { |line| JSON.parse(line) } : []
  def scope = { "window_id" => 1 }

  # --- the handshake -----------------------------------------------------------------------------

  # The initialized notification is fire-and-forget, so it is only certainly on the wire once a later
  # request has been answered — the server handles messages in order.
  def test_starting_handshakes_and_reports_one_browser_instance
    made = bridge

    assert_equal 1, made.start
    made.request("windows")
    assert_equal(%w[initialize notifications/initialized tools/call], rpc_calls.map { _1["method"] })
  end

  def test_starting_twice_handshakes_once
    made = bridge
    made.start
    made.start

    assert_equal(1, rpc_calls.count { _1["method"] == "initialize" })
  end

  def test_a_server_that_refuses_the_handshake_says_so
    error = assert_raises(Wrangle::BridgeCallError) { bridge(refuse_initialize: true).start }

    assert_match(/refused initialize/, error.message)
    assert_match(/no automation for you/, error.message)
  end

  def test_a_missing_safaridriver_is_reported_as_a_missing_safaridriver
    made = Wrangle::McpBridge.new(command: ["/nonexistent/safaridriver", "--mcp"])
    error = assert_raises(Wrangle::BridgeError) { made.start }

    assert_match(/Safari 27 or newer/, error.message)
  end

  # --- the page protocol -------------------------------------------------------------------------

  def test_opening_navigates_installs_the_runtime_and_reports_the_tab
    result = opened.request("open", url: "https://fixture.test/stays")

    assert_equal 1, result["window_id"]
    assert_equal "https://fixture.test/stays", result["url"]
    assert_nil result["bounds"]
  end

  # The same page request the Apple Events bridge sends, over a different pipe. The fake echoes it
  # back, so this checks the bridge ships the request unmangled rather than that Safari understood it.
  def test_a_page_request_is_evaluated_and_its_json_decoded
    result = opened.evaluate(scope, { "op" => "observe" })

    assert_equal "ok", result["status"]
    assert_equal "observe", result["op"]
  end

  def test_evaluating_without_a_scope_and_a_request_is_a_programming_error
    assert_raises(ArgumentError) { opened.evaluate(nil, { "op" => "observe" }) }
    assert_raises(ArgumentError) { opened.evaluate(scope, "observe") }
  end

  def test_a_page_returning_something_that_is_not_json_is_reported_as_such
    error = assert_raises(Wrangle::BridgeError) { opened(bad_json: true).evaluate(scope, { "op" => "observe" }) }

    assert_match(/invalid JSON/, error.message)
  end

  def test_a_failing_tool_call_names_the_tool
    error = assert_raises(Wrangle::BridgeCallError) { opened(tool_error: true).evaluate(scope, { "op" => "observe" }) }

    assert_match(/evaluate_javascript tool failed/, error.message)
    assert_match(/JavaScript exception/, error.message)
  end

  def test_an_unreadable_tab_list_is_reported_rather_than_returned_as_nothing
    made = bridge(bad_tab_list: true)
    made.start

    assert_raises(Wrangle::BridgeError) { made.request("windows") }
  end

  # --- a replaced document -----------------------------------------------------------------------

  # A navigation takes the installed runtime with it. Reinstalling and asking again is safe for a
  # read, and the observation that comes back is the fresh page.
  def test_a_read_whose_runtime_vanished_is_reinstalled_and_retried
    made = opened(runtime_missing: 1)

    assert_equal "ok", made.evaluate(scope, { "op" => "observe" })["status"]
  end

  # The rule the whole backend rests on: an act whose runtime vanished may have been delivered before
  # the document went. Re-sending it could click twice, so it is reported as a lost epoch and left
  # for the session to resolve by reading the page back.
  def test_an_act_whose_runtime_vanished_is_never_re_sent
    made = opened(runtime_missing: 1)
    result = made.evaluate(scope, { "op" => "act", "node" => 7 })

    assert_equal "epoch_lost", result["status"]
    acts = rpc_calls.count { _1.dig("params", "arguments", "expression").to_s.include?('"op":"act"') }
    assert_equal 1, acts
  end

  def test_a_runtime_that_will_not_install_gives_up_rather_than_looping
    made = opened(runtime_missing: 99)
    error = assert_raises(Wrangle::BridgeError) { made.evaluate(scope, { "op" => "observe" }) }

    assert_match(/would not install/, error.message)
  end

  # --- what it does not do -----------------------------------------------------------------------

  # Each of these is a real capability gap rather than a missing feature, and the message has to say
  # which, because the caller's next move is to switch backends.
  def test_unsupported_operations_explain_themselves_and_name_the_alternative
    made = bridge
    made.start

    %w[attach displays bounds].each do |op|
      error = assert_raises(Wrangle::BridgeCallError) { made.request(op) }

      assert_equal "unsupported", error.code
      assert_match(/backend/, error.message)
    end
  end

  def test_opening_with_a_display_is_refused_rather_than_quietly_ignored
    made = bridge
    made.start
    error = assert_raises(Wrangle::BridgeCallError) { made.request("open", url: "https://fixture.test", display: 1) }

    assert_match(/cannot honour --display/, error.message)
  end

  def test_opening_without_a_url_is_a_usage_error
    made = bridge
    made.start

    assert_equal "usage", assert_raises(Wrangle::BridgeCallError) { made.request("open") }.code
  end

  # --- the pipe ----------------------------------------------------------------------------------

  # A hang is the failure a session cannot recover from on its own, so it has to become an error the
  # caller can see rather than a command that never returns.
  def test_a_server_that_never_answers_times_out
    made = opened(silent: true, request_timeout: 0.4)
    error = assert_raises(Wrangle::BridgeError) { made.evaluate(scope, { "op" => "observe" }) }

    assert_match(/did not reply in time/, error.message)
  end

  def test_a_server_that_dies_holding_a_request_is_reported_rather_than_hanging
    made = opened(die: true, request_timeout: 2)
    error = assert_raises(Wrangle::BridgeError) { made.evaluate(scope, { "op" => "observe" }) }

    assert_match(/closed the connection/, error.message)
  end

  def test_a_closed_bridge_stops_accepting_requests
    made = bridge
    made.start
    made.close

    refute_predicate made, :running?
    assert_raises(Wrangle::BridgeError) { made.evaluate(scope, { "op" => "observe" }) }
  end

  # --- replies that parse but are not results ------------------------------------------------------

  def test_a_page_reply_with_no_status_is_not_a_result
    made = opened(statusless: true)

    error = assert_raises(Wrangle::BridgeError) { made.evaluate(scope, { "op" => "observe" }) }

    assert_match(/invalid result/, error.message)
  end

  # The MCP content array is the envelope, and an envelope with nothing readable in it is not an
  # answer however well-formed the JSON-RPC around it is.
  def test_a_tool_reply_carrying_no_text_is_refused
    made = opened(textless: true)

    error = assert_raises(Wrangle::BridgeError) { made.evaluate(scope, { "op" => "observe" }) }

    assert_match(/returned no text/, error.message)
  end

  # --- the rest of the operation table -----------------------------------------------------------

  # Every other backend starts lazily, and a caller that has a bridge should not have to know which
  # one it is holding.
  def test_a_request_starts_the_server_if_nobody_did
    made = bridge

    assert made.request("ping")["ok"]
    assert_includes rpc_calls.map { _1["method"] }, "initialize"
  end

  def test_evaluating_starts_the_server_too
    made = bridge
    made.request("open", url: "https://fixture.test/stays")

    assert_equal "ok", made.evaluate(scope, { "op" => "observe" })["status"]
  end

  def test_an_operation_with_no_rule_at_all_is_refused_by_name
    error = assert_raises(Wrangle::BridgeCallError) { bridge.request("teleport") }

    assert_equal "unsupported", error.code
    assert_match(/does not support "teleport"/, error.message)
  end

  # --- closing the tab -----------------------------------------------------------------------------

  def test_closing_a_tab_that_was_never_opened_closes_nothing
    made = bridge
    made.start

    refute made.request("close")["closed"]
    refute_includes rpc_calls.map { _1.dig("params", "name") }, "close_tab"
  end

  def test_closing_an_open_tab_closes_it_once
    made = opened

    assert made.request("close")["closed"]
    refute made.request("close")["closed"], "the handle is spent, so there is nothing left to close"
    assert_equal(1, rpc_calls.count { _1.dig("params", "name") == "close_tab" })
  end

  # A tab list that parses but is not a list is not a list of tabs.
  def test_a_tab_list_that_is_not_a_list_is_reported_as_no_tabs
    made = bridge(tab_list_not_an_array: true)
    made.start

    assert_empty made.request("windows")["windows"]
  end

  def test_closing_twice_is_harmless
    made = bridge
    made.start
    made.close
    made.close
  end
end
