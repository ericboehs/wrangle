# frozen_string_literal: true

require_relative "test_helper"

class DesktopSessionServerTest < Minitest::Test
  class FakeProvider
    attr_reader :capabilities

    def initialize(*choices, qualified: true)
      @choices = choices
      @capabilities = Wrangle::DecisionProvider::Capabilities.new(
        protocol: Wrangle::DecisionProvider::PROTOCOL, max_choices: 16, confidence: true,
        hierarchical: true, mutation_qualified: qualified, provider: "fixture", model: "recorded-v1",
        runtime: "ruby", transport: "memory"
      )
    end

    def choose(state:, name:, criteria:, instructions:)
      choice, confidence = @choices.shift
      raise "#{choice} was not offered for #{name}" unless criteria.key?(choice)
      raise "missing state or instructions" if state.empty? || instructions.empty?

      rest = (1.0 - confidence) / (criteria.length - 1)
      probabilities = criteria.to_h { |key, _| [key, key == choice ? confidence : rest] }
      Wrangle::DecisionProvider::Decision.new(choice:, confidence:, probabilities:, latency_ms: 1.0)
    end

    def mutation_qualified? = capabilities.mutation_qualified
  end

  class EvidenceFailureProvider < FakeProvider
    def initialize
      super(["DONE", 0.9])
      @calls = 0
    end

    def choose(**arguments)
      @calls += 1
      raise Wrangle::ProviderError, "evidence unavailable" if @calls > 1

      super
    end
  end

  class FakeLog
    attr_reader :events

    def initialize = @events = []

    def record(type, fields = nil, durable: false, **implicit_fields)
      @events << (fields || {}).merge(implicit_fields).merge("event" => type, "durable" => durable)
    end
  end

  class FakeRegistry
    Lease = Struct.new(:mode)
    Dispatch = Struct.new(:token)
    attr_reader :released, :dispatch_started, :dispatch_finished

    def acquire(_scope, mode:) = Lease.new(mode)
    def release(lease) = @released = lease

    def begin_dispatch(_scope, **metadata)
      @dispatch_started = metadata
      Dispatch.new("dispatch-token")
    end

    def finish_dispatch(dispatch) = @dispatch_finished = dispatch
  end

  class FakeDriver
    attr_accessor :failure, :execute_failure, :observations, :dispatch_result, :found_windows
    attr_reader :closed, :attached, :executed, :drilled, :window_request, :observed_skeletons

    def initialize
      @observations = [state("one", "Open")]
      @dispatch_result = { "dispatch" => "delivered" }
      @found_windows = [{ "id" => "w-1", "app_name" => "Finder", "focused" => true }]
      @observed_skeletons = []
    end

    def windows(app:, titles:)
      @window_request = [app, titles]
      found_windows
    end

    def attach(window_id:, app:)
      @attached = [window_id, app]
      DesktopSessionServerTest.scope
    end

    def observe(_scope, skeleton: true)
      @observed_skeletons << skeleton
      raise failure if failure

      value = observations.length > 1 ? observations.shift : observations.first
      raise value if value.is_a?(Exception)

      value
    end

    def drill(scope, **view)
      @drilled = view
      observe(scope)
    end

    def execute(_scope, **action)
      @executed = action
      raise execute_failure if execute_failure

      dispatch_result
    end

    def close = @closed = true

    def state(revision, label, role: "button", value: nil, states: ["enabled"], operations: ["PRESS"],
              ref: "@s:e1", truncated: false)
      candidate = { "ref" => ref, "role" => role, "label" => label,
                    "value" => value, "states" => states, "operations" => operations }
      { "schema" => "wrangle.observation.v1", "snapshot_id" => "snap-#{revision}",
        "revision" => revision, "complete" => !truncated,
        "scope" => { "id" => "scope-1", "root" => "w-1", "app" => "Finder" },
        "coverage" => { "candidate_count" => 1, "provenance" => ["ax"], "truncated" => truncated },
        "candidates" => [candidate] }
    end
  end

  def self.scope
    Wrangle::MacOSDriver::Scope.new(id: "scope-1", root: "w-1", app: "Finder",
                                    bundle_id: "com.apple.finder", pid: 42,
                                    process_instance: "proc-42", bounds: {}, display_id: "display-1",
                                    attached_at: "now")
  end

  def setup
    @directory = Dir.mktmpdir("wrangle-desktop-server")
    @socket = File.join(@directory, "server.sock")
    @driver = FakeDriver.new
    @registry = FakeRegistry.new
    @log = FakeLog.new
  end

  def teardown
    @thread&.kill
    @thread&.join
    FileUtils.remove_entry(@directory) if File.directory?(@directory)
  end

  def test_serves_status_observe_inspect_and_close
    client = serving
    status = client.call("status").fetch("value")
    assert_equal "macos", status["driver"]
    assert_equal "w-1", status["root"]
    refute status["owned"]
    refute status["observed"]
    assert_equal "exclusive", status["concurrency"]

    first = client.call("observe").fetch("value")
    assert_nil first["changed"]
    assert_equal 1, first.dig("candidates", 0, "ref")
    assert_equal "PRESS", first.dig("candidates", 0, "operations", 0)
    assert_equal "one", client.call("inspect").dig("value", "revision")

    closed = client.call("close")
    assert closed["ok"]
    assert closed.dig("value", "root_preserved")
    assert_equal "Wrangle released control; the application window remains open", closed.dig("value", "message")
    @thread.join(1)
    assert @driver.closed
    refute_nil @registry.released
    refute File.exist?(@socket)
  end

  def test_reports_candidate_deltas_without_literal_values
    @driver.observations = [@driver.state("one", "Open"), @driver.state("two", "Close")]
    client = serving
    client.call("observe")
    changed = client.call("observe").dig("value", "changed")

    refute changed["same"]
    assert_equal ["button:Close"], changed["appeared"]
    assert_equal ["button:Open"], changed["disappeared"]
  end

  def test_server_attaches_when_a_scope_is_not_injected
    server = Wrangle::DesktopSessionServer.new(
      @socket, { "window_id" => "w-1", "app" => "Finder" },
      driver: @driver, registry: @registry, log: @log
    )
    @thread = Thread.new { server.run }
    @thread.report_on_exception = false
    wait_for_socket
    client = Wrangle::SessionClient.new(@socket)

    assert_equal %w[w-1 Finder], @driver.attached
    client.call("close")
  end

  def test_refusals_name_terminal_delivery_and_recovery
    server = server_seam

    reply = server.send(:dispatch, "op" => "inspect")
    refute reply["ok"]
    refute reply["terminal"]
    assert_equal "Observe again.", reply["hint"]

    @driver.failure = Wrangle::ScopeLost.new("gone")
    terminal = server.send(:dispatch, "op" => "observe")
    assert terminal["terminal"]
    assert_match(/Attach again/, terminal["hint"])

    @driver.failure = Wrangle::DriverRefusal.new("TIMEOUT", "unknown", delivery: "unknown")
    assert server.send(:dispatch, "op" => "observe")["terminal"]

    @driver.failure = Wrangle::DriverUnavailable.new("upgrade required")
    assert server.send(:dispatch, "op" => "observe")["terminal"]

    @driver.failure = RuntimeError.new("bug")
    internal = server.send(:dispatch, "op" => "observe")
    assert internal["terminal"]
    assert_match(/internal error/, internal["error"])
  end

  def test_single_task_runs_the_bounded_loop_and_hides_internal_capabilities
    before = @driver.state("one", "Open")
    after = @driver.state("two", "Close")
    @driver.observations = [before, before, after]
    server = server_seam(provider: FakeProvider.new(["a1", 0.9], ["DONE", 0.95]))

    result = server.send(:autonomous_task, "goal" => "Open the fixture", "steps" => 3)

    assert_equal "wrangle.task.v1", result["schema"]
    assert_equal "done", result["status"]
    assert_equal 1, result["actions_taken"]
    assert_equal "delivered", result.dig("actions", 0, "dispatch")
    assert_equal "verified", result.dig("actions", 0, "effect")
    assert_equal "Close", result.dig("evidence", "items", 0, "label")
    assert_equal "PRESS", @registry.dispatch_started[:operation]
    refute_nil @registry.dispatch_finished
    assert @log.events.find { |event| event["event"] == "execute" }["durable"]
    refute_includes JSON.generate(result), "proposal_id"
    refute_includes JSON.generate(result), "@s:e1"
  end

  def test_single_task_escalates_a_partial_skeleton_and_redecides_before_action
    partial = @driver.state("partial", "Join a meeting", truncated: true)
    complete = @driver.state("complete", "Join a meeting")
    fresh = @driver.state("complete", "Join a meeting", ref: "@fresh:e1")
    after = @driver.state("after", "Meeting code", role: "textfield", operations: %w[SET_TEXT CLEAR])
    @driver.observations = [partial, complete, fresh, after]
    provider = FakeProvider.new(["a1", 0.9], ["a1", 0.92], ["DONE", 0.95])
    server = server_seam(provider:)

    result = server.send(
      :autonomous_task,
      "goal" => "Open the Join a meeting form without joining a meeting", "steps" => 2
    )

    assert_equal "done", result["status"]
    assert_equal 1, result["actions_taken"]
    assert_equal "verified", result.dig("actions", 0, "effect")
    assert_equal [true, false, false, false], @driver.observed_skeletons
    assert_equal "@fresh:e1", @driver.executed[:ref]
    escalation = @log.events.find { |event| event["event"] == "observe_escalated" }
    assert escalation
    assert escalation["complete"]
    refute escalation.key?("label")
  end

  def test_single_task_can_escalate_without_optional_logging
    partial = @driver.state("partial", "Open", truncated: true)
    complete = @driver.state("complete", "Open")
    @driver.observations = [partial, complete]
    provider = FakeProvider.new(["a1", 0.9], ["HANDOFF", 0.9])
    server = server_seam(provider:, log: nil)

    result = server.send(:autonomous_task, "goal" => "Open the fixture", "steps" => 1)

    assert_equal "handoff", result["status"]
    assert_equal [true, false], @driver.observed_skeletons
    assert_nil @driver.executed
  end

  def test_single_task_refuses_when_escalated_observation_is_still_partial
    partial = @driver.state("partial", "Open", truncated: true)
    still_partial = @driver.state("full", "Open", truncated: true)
    @driver.observations = [partial, still_partial]
    server = server_seam(provider: FakeProvider.new(["a1", 0.9]))

    error = assert_raises(Wrangle::PartialObservation) do
      server.send(:autonomous_task, "goal" => "Open the fixture", "steps" => 1)
    end

    assert_match(/Full desktop observation/, error.message)
    assert_equal [true, false], @driver.observed_skeletons
    assert_nil @driver.executed
  end

  def test_single_task_refuses_to_replace_a_partial_drilled_view_with_the_root
    top = @driver.state("top", "Group", operations: ["DRILL"], truncated: true)
    detail = @driver.state("detail", "Open", truncated: true)
    @driver.observations = [top, detail]
    provider = FakeProvider.new(["a1", 0.9], ["a1", 0.9])
    server = server_seam(provider:)

    error = assert_raises(Wrangle::PartialObservation) do
      server.send(:autonomous_task, "goal" => "Open the nested item", "steps" => 1)
    end

    assert_match(/progressive view/, error.message)
    assert @driver.drilled
    assert_nil @driver.executed
  end

  def test_single_task_does_not_escalate_partial_observation_for_terminal_decision
    partial = @driver.state("partial", "Visible content", truncated: true)
    @driver.observations = [partial]
    server = server_seam(provider: FakeProvider.new(["DONE", 0.95]))

    result = server.send(:autonomous_task, "goal" => "Confirm content is visible", "steps" => 1)

    assert_equal "done", result["status"]
    assert_equal [true], @driver.observed_skeletons
    refute(@log.events.any? { |event| event["event"] == "observe_escalated" })
  end

  def test_single_task_uses_typed_provider_selection_for_large_evidence
    state = @driver.state("many", "Item 1")
    state["coverage"]["candidate_count"] = 13
    state["candidates"] = 13.times.map do |index|
      state["candidates"].first.merge("label" => "Item #{index + 1}", "ref" => "@s:e#{index + 1}")
    end
    @driver.observations = [state]
    provider = FakeProvider.new(["DONE", 0.9], ["e8", 0.9], ["ENOUGH", 0.9])

    result = server_seam(provider:).send(:autonomous_task, "goal" => "Report item eight")

    assert_equal "provider", result.dig("evidence", "selection")
    labels = result.dig("evidence", "items").map { |item| item["label"] }
    assert_equal ["Item 8"], labels
    assert_equal 12, result.dig("evidence", "omitted")
  end

  def test_single_task_falls_back_explicitly_when_evidence_selection_fails
    state = @driver.state("many", "Item 1")
    state["candidates"] = 13.times.map do |index|
      state["candidates"].first.merge("label" => "Item #{index + 1}", "ref" => "@s:e#{index + 1}")
    end
    @driver.observations = [state]

    result = server_seam(provider: EvidenceFailureProvider.new).send(
      :autonomous_task, "goal" => "Report visible items"
    )

    assert_equal "done", result["status"]
    assert_equal "provider_failed", result.dig("evidence", "selection")
    assert_equal 12, result.dig("evidence", "items").length
    assert result.dig("evidence", "explicit_truncation")
  end

  def test_single_task_uses_exact_quoted_text_without_echoing_it
    before = @driver.state("one", "Message", role: "textfield", value: "",
                                             operations: %w[SET_TEXT CLEAR PRESS])
    after = @driver.state("two", "Message", role: "textfield", value: "private draft",
                                            operations: %w[SET_TEXT CLEAR PRESS])
    @driver.observations = [before, before, after]
    provider = FakeProvider.new(["a1", 0.9], ["DONE", 0.9])
    result = server_seam(provider:).send(:autonomous_task, "goal" => "Enter 'private draft'")

    assert_equal "done", result["status"]
    assert_equal "private draft", @driver.executed[:text]
    refute_includes JSON.generate(result), "private draft"
    refute_includes JSON.generate(@log.events), "private draft"
    assert_equal "[typed text omitted]", result.dig("evidence", "items", 0, "value")
  end

  def test_single_task_reports_low_confidence_budget_and_terminal_verification
    low = server_seam(provider: FakeProvider.new(["a1", 0.2])).send(
      :autonomous_task, "goal" => "Open it", "min_confidence" => 0.8
    )
    assert_equal "low_confidence", low["status"]
    assert_nil @driver.executed

    @driver = FakeDriver.new
    terminal_low = server_seam(provider: FakeProvider.new(["DONE", 0.2])).send(
      :autonomous_task, "goal" => "Confirm it", "min_confidence" => 0.8
    )
    assert_equal "low_confidence", terminal_low["status"]
    assert_equal "DONE", terminal_low.dig("decision", "operation")
    assert_nil @driver.executed

    @driver = FakeDriver.new
    state = @driver.state("one", "Open")
    @driver.observations = [state, state, @driver.state("two", "Close")]
    exhausted = server_seam(provider: FakeProvider.new(["a1", 0.9])).send(
      :autonomous_task, "goal" => "Keep working", "steps" => 1
    )
    assert_equal "budget_exhausted", exhausted["status"]
    assert_equal 0, exhausted["remaining"]

    @driver = FakeDriver.new
    state = @driver.state("one", "Open")
    @driver.observations = [state, state, Wrangle::ScopeLost.new("gone")]
    terminal = server_seam(provider: FakeProvider.new(["a1", 0.9])).send(
      :autonomous_task, "goal" => "Open it"
    )
    assert_equal "terminal", terminal["status"]
    assert terminal.dig("actions", 0, "terminal")
  end

  def test_single_task_caps_progressive_drills
    drill = @driver.state("drill", "Group", operations: ["DRILL"], truncated: true)
    @driver.observations = Array.new(5) { drill }
    provider = FakeProvider.new(["a1", 0.9], ["a1", 0.9], ["a1", 0.9], ["a1", 0.9])

    error = assert_raises(Wrangle::PartialObservation) do
      server_seam(provider:).send(:autonomous_task, "goal" => "Inspect nested content")
    end
    assert_match(/task exceeded/, error.message)
  end

  def test_single_task_returns_non_actionable_visible_text_as_evidence
    state = @driver.state("one", "Open")
    state["tree"] = { "role" => "window", "children" => [
      { "role" => "statictext", "name" => "Read-only status", "value" => "Ready" }
    ] }
    @driver.observations = [state]

    result = server_seam(provider: FakeProvider.new(["DONE", 0.9])).send(
      :autonomous_task, "goal" => "Read the status"
    )

    visible = result.dig("evidence", "items").find { |item| item["label"] == "Read-only status" }
    assert_equal "Ready", visible["value"]
  end

  def test_single_task_bounds_long_evidence_values
    long = @driver.state("one", "Report", value: "x" * 600)
    @driver.observations = [long]

    result = server_seam(provider: FakeProvider.new(["DONE", 0.9])).send(
      :autonomous_task, "goal" => "Read the report"
    )

    value = result.dig("evidence", "items", 0, "value")
    assert_equal 501, value.length
    assert value.end_with?("…")
  end

  def test_single_task_enforces_the_evidence_byte_limit
    state = @driver.state("many", "Item 1", value: "x" * 600)
    state["candidates"] = 12.times.map do |index|
      state["candidates"].first.merge("label" => "Item #{index + 1}", "ref" => "@s:e#{index + 1}")
    end
    @driver.observations = [state]

    result = server_seam(provider: FakeProvider.new(["BLOCKED", 0.9])).send(
      :autonomous_task, "goal" => "Find an unavailable item"
    )

    assert_equal "blocked", result["status"]
    assert_operator result.dig("evidence", "items").length, :<, 12
    assert_operator JSON.generate(result.fetch("evidence")).bytesize, :<=,
                    Wrangle::DesktopSessionAutonomy::TASK_EVIDENCE_BYTES + 300
  end

  def test_single_task_stops_before_consequential_or_unqualified_mutation
    consequential = @driver.state("one", "Send")
    @driver.observations = [consequential]
    server = server_seam(provider: FakeProvider.new(["a1", 0.9]))
    result = server.send(:autonomous_task, "goal" => "Send it")
    assert_equal "approval_required", result["status"]
    assert_equal "Send", result.dig("pending_action", "label")
    assert_nil @driver.executed

    @driver = FakeDriver.new
    unqualified = server_seam(provider: FakeProvider.new(["a1", 0.9], qualified: false))
    result = unqualified.send(:autonomous_task, "goal" => "Open it")
    assert_equal "provider_not_qualified", result["status"]
    assert_nil @driver.executed
  end

  def test_single_task_stops_on_failed_or_unknown_delivery_without_retry
    %w[not_delivered delivery_unknown].each do |dispatch|
      @driver = FakeDriver.new
      state = @driver.state("one", "Open")
      @driver.observations = [state, state, state]
      @driver.dispatch_result = { "dispatch" => dispatch, "code" => "FIXTURE" }
      server = server_seam(provider: FakeProvider.new(["a1", 0.9]))

      result = server.send(:autonomous_task, "goal" => "Open it")

      assert_equal dispatch, result["status"]
      assert_equal(dispatch == "delivery_unknown" ? 1 : 0, result["actions_taken"])
      assert_equal dispatch, result.dig("actions", 0, "dispatch")
      assert_equal 8, result["remaining"]
    end
  end

  def test_single_task_runtime_releases_its_lease_and_closes_the_driver
    server = server_seam(provider: FakeProvider.new(["DONE", 0.9]))

    result = server.run_task("goal" => "Confirm it")

    assert_equal "done", result["status"]
    assert @driver.closed
    refute_nil @registry.released
    assert_equal "exclusive", @registry.released.mode
  end

  def test_desktop_task_selects_one_window_and_fails_closed_on_ambiguity
    task = Wrangle::DesktopTask.new(
      driver: @driver, provider: FakeProvider.new(["DONE", 0.9]), registry: @registry, log: @log
    )
    result = task.run(app: "Finder", goal: "Inspect it")
    assert_equal "done", result["status"]
    assert_equal ["Finder", true], @driver.window_request
    assert_equal %w[w-1 Finder], @driver.attached

    @driver = FakeDriver.new
    @driver.found_windows = [
      { "id" => "w-1", "app_name" => "Finder", "focused" => false },
      { "id" => "w-2", "app_name" => "Finder", "focused" => false }
    ]
    task = Wrangle::DesktopTask.new(driver: @driver, provider: FakeProvider.new(["DONE", 0.9]))
    error = assert_raises(Wrangle::ScopeLost) { task.run(app: "Finder", goal: "Inspect it") }
    assert_match(/More than one/, error.message)
    assert @driver.closed

    @driver = FakeDriver.new
    @driver.found_windows = []
    task = Wrangle::DesktopTask.new(driver: @driver, provider: FakeProvider.new(["DONE", 0.9]))
    assert_raises(Wrangle::ScopeLost) { task.run(app: "Finder", goal: "Inspect it") }
    assert @driver.closed
  end

  def test_desktop_task_prefers_the_unique_focused_window_and_validates_inputs
    @driver.found_windows = [
      { "id" => "w-1", "app_name" => "Finder", "focused" => false },
      { "id" => "w-2", "app_name" => "Finder", "focused" => true }
    ]
    task = Wrangle::DesktopTask.new(
      driver: @driver, provider: FakeProvider.new(["DONE", 0.9]), registry: @registry, log: @log
    )
    task.run(app: "Finder", goal: "Inspect it")
    assert_equal %w[w-2 Finder], @driver.attached

    assert_raises(ArgumentError) do
      Wrangle::DesktopTask.new(driver: FakeDriver.new, provider: FakeProvider.new(["DONE", 0.9]))
                          .run(app: "", goal: "Inspect")
    end
    assert_raises(ArgumentError) do
      Wrangle::DesktopTask.new(driver: FakeDriver.new, provider: FakeProvider.new(["DONE", 0.9]))
                          .run(app: "Finder", goal: "Inspect", steps: 9)
    end
  end

  def test_provider_preview_reuses_an_existing_observation_without_a_log
    provider = FakeProvider.new(["a1", 0.9])
    server = server_seam(provider:, log: nil)
    server.send(:dispatch, "op" => "observe")

    decision = server.send(:dispatch, "op" => "preview", "goal" => "Open the fixture").fetch("value")
    assert_equal "PRESS", decision["operation"]
    assert decision["proposal"]
    assert_nil @driver.executed
  end

  def test_provider_preview_proposes_an_observed_action_without_dispatching
    before = @driver.state("one", "Open")
    after = @driver.state("two", "Close")
    @driver.observations = [before, before, after]
    provider = FakeProvider.new(["a1", 0.9])
    server = server_seam(provider:)

    decision = server.send(:dispatch, "op" => "preview", "goal" => "Open the fixture").fetch("value")
    assert_equal "wrangle.decision.v1", decision["schema"]
    assert_equal "PRESS", decision["operation"]
    assert_equal "fixture", decision["provider"]
    assert decision.dig("proposal", "policy", "provider_qualified")
    assert_nil @driver.executed

    proposal_id = decision.dig("proposal", "proposal_id")
    receipt = server.send(:dispatch, "op" => "execute", "proposal_id" => proposal_id).fetch("value")
    assert_equal "delivered", receipt["dispatch"]
  end

  def test_provider_progressive_drill_budget_and_confidence_range_fail_closed
    drill = @driver.state("drill", "Group", operations: ["DRILL"], truncated: true)
    @driver.observations = Array.new(Wrangle::DesktopAutonomy::DRILL_BUDGET + 1) { drill }
    choices = Array.new(Wrangle::DesktopAutonomy::DRILL_BUDGET) { ["a1", 0.9] }
    server = server_seam(provider: FakeProvider.new(*choices))

    exhausted = server.send(:dispatch, "op" => "preview", "goal" => "Open nested item")
    assert_equal "PartialObservation", exhausted["class"]
    assert_match(/DRILL budget/, exhausted["error"])

    @driver.observations = [@driver.state("one", "Open")]
    invalid = server_seam(provider: FakeProvider.new(["DONE", 0.9])).send(
      :dispatch, "op" => "preview", "goal" => "Confirm", "min_confidence" => 2
    )
    assert_equal "ArgumentError", invalid["class"]
    assert_match(/between zero and one/, invalid["error"])
  end

  def test_provider_terminal_low_confidence_and_missing_provider_pause_without_action
    done = server_seam(provider: FakeProvider.new(["DONE", 0.9]))
    value = done.send(:dispatch, "op" => "preview", "goal" => "Confirm the fixture").fetch("value")
    assert value["terminal"]
    assert_equal "DONE", value["operation"]
    refute value.key?("proposal")

    @driver.observations = [@driver.state("one", "Open")]
    low_done = server_seam(provider: FakeProvider.new(["DONE", 0.2]))
    value = low_done.send(
      :dispatch, "op" => "preview", "goal" => "Confirm", "min_confidence" => 0.8
    ).fetch("value")
    assert_equal "low_confidence", value["paused"]
    assert_equal "DONE", value["operation"]
    refute value.key?("proposal")

    @driver.observations = [@driver.state("one", "Open")]
    low = server_seam(provider: FakeProvider.new(["a1", 0.2]))
    value = low.send(:dispatch, "op" => "preview", "goal" => "Open", "min_confidence" => 0.8).fetch("value")
    assert_equal "low_confidence", value["paused"]
    refute value.key?("proposal")

    missing = server_seam.send(:dispatch, "op" => "preview", "goal" => "Open")
    assert_equal "ConfigurationError", missing["class"]
  end

  def test_authorized_run_continues_safe_actions_within_budget
    first = @driver.state("one", "Open")
    second = @driver.state("two", "Next")
    final = @driver.state("three", "Done")
    @driver.observations = [first, first, second, second, final]
    provider = FakeProvider.new(["a1", 0.9], ["a1", 0.9], ["DONE", 0.9])
    server = server_seam(provider:)
    decision = server.send(:dispatch, "op" => "preview", "goal" => "Finish", "steps" => 3).fetch("value")

    unauthorized = server.send(:dispatch, "op" => "continue", "run_id" => decision["run_id"])
    assert_equal "PolicyDenied", unauthorized["class"]
    first_receipt = server.send(:dispatch, "op" => "execute",
                                           "proposal_id" => decision.dig("proposal", "proposal_id")).fetch("value")
    assert first_receipt["can_continue"]

    result = server.send(:dispatch, "op" => "continue", "run_id" => decision["run_id"]).fetch("value")
    assert_equal "done", result["status"]
    assert_equal 1, result["receipts"].length
    assert_equal 1, result["remaining"]
    assert_equal 2, server.send(:dispatch, "op" => "status").dig("value", "actions_taken")
    assert_equal "ArgumentError", server.send(:dispatch, "op" => "continue", "run_id" => decision["run_id"])["class"]
  end

  def test_continuation_reports_budget_exhaustion_after_last_authorized_action
    first = @driver.state("one", "Open")
    second = @driver.state("two", "Next")
    final = @driver.state("three", "Done")
    @driver.observations = [first, first, second, second, final]
    server = server_seam(provider: FakeProvider.new(["a1", 0.9], ["a1", 0.9]))
    decision = server.send(:dispatch, "op" => "preview", "goal" => "Finish", "steps" => 2).fetch("value")
    server.send(:dispatch, "op" => "execute", "proposal_id" => decision.dig("proposal", "proposal_id"))

    result = server.send(:dispatch, "op" => "continue", "run_id" => decision["run_id"]).fetch("value")
    assert_equal "budget_exhausted", result["status"]
    assert_equal 0, result["remaining"]
    assert_equal 1, result["receipts"].length
  end

  def test_continuation_low_confidence_terminates_the_run_without_dispatch
    first = @driver.state("one", "Open")
    second = @driver.state("two", "Next")
    @driver.observations = [first, first, second]
    provider = FakeProvider.new(["a1", 0.9], ["a1", 0.2])
    server = server_seam(provider:)
    decision = server.send(:dispatch, "op" => "preview", "goal" => "Finish", "min_confidence" => 0.8).fetch("value")
    server.send(:dispatch, "op" => "execute", "proposal_id" => decision.dig("proposal", "proposal_id"))

    result = server.send(:dispatch, "op" => "continue", "run_id" => decision["run_id"]).fetch("value")
    assert_equal "low_confidence", result["status"]
    assert_equal "low_confidence", result.dig("decision", "paused")
    assert_empty result["receipts"]
    assert_equal 1, server.send(:dispatch, "op" => "status").dig("value", "actions_taken")
  end

  def test_invalid_run_budget_is_refused_before_a_proposal_is_returned
    server = server_seam(provider: FakeProvider.new(["a1", 0.9]))
    reply = server.send(:dispatch, "op" => "preview", "goal" => "Open", "steps" => 0)

    assert_equal "ArgumentError", reply["class"]
    assert_match(/budget/, reply["error"])
    assert_nil @driver.executed
  end

  def test_run_budget_exhaustion_disables_continuation_and_cleans_up
    state = @driver.state("one", "Open")
    after = @driver.state("two", "Done")
    @driver.observations = [state, state, after]
    server = server_seam(provider: FakeProvider.new(["a1", 0.9]))
    decision = server.send(:dispatch, "op" => "preview", "goal" => "Open", "steps" => 1).fetch("value")

    receipt = server.send(:dispatch, "op" => "execute",
                                     "proposal_id" => decision.dig("proposal", "proposal_id")).fetch("value")
    refute receipt["can_continue"]
    assert_equal decision["run_id"], receipt["run_id"]
    assert_equal "ArgumentError", server.send(:dispatch, "op" => "continue", "run_id" => decision["run_id"])["class"]
  end

  def test_continuation_pauses_before_a_new_consequential_action
    first = @driver.state("one", "Open")
    send_button = @driver.state("two", "Send")
    @driver.observations = [first, first, send_button]
    provider = FakeProvider.new(["a1", 0.9], ["a1", 0.9])
    server = server_seam(provider:)
    decision = server.send(:dispatch, "op" => "preview", "goal" => "Prepare").fetch("value")
    server.send(:dispatch, "op" => "execute", "proposal_id" => decision.dig("proposal", "proposal_id"))

    result = server.send(:dispatch, "op" => "continue", "run_id" => decision["run_id"]).fetch("value")
    assert_equal "approval_required", result["status"]
    assert result.dig("proposal", "policy", "consequential")
    assert_empty result["receipts"]

    pending = server.send(:dispatch, "op" => "continue", "run_id" => decision["run_id"])
    assert_equal "PolicyDenied", pending["class"]
    assert_match(/pending consequential/, pending["error"])
  end

  def test_initial_consequential_proposal_requires_approval_before_authorizing_run
    state = @driver.state("one", "Send")
    after = @driver.state("two", "Sent")
    @driver.observations = [state, state, after]
    server = server_seam(provider: FakeProvider.new(["a1", 0.9]))
    decision = server.send(:dispatch, "op" => "preview", "goal" => "Send prepared message").fetch("value")
    proposal_id = decision.dig("proposal", "proposal_id")

    refused = server.send(:dispatch, "op" => "execute", "proposal_id" => proposal_id).fetch("value")
    assert_equal "approval_required", refused["reason"]
    assert_equal decision["run_id"], refused["run_id"]
    refute refused["can_continue"]
    assert_equal "PolicyDenied", server.send(:dispatch, "op" => "continue", "run_id" => decision["run_id"])["class"]

    delivered = server.send(:dispatch, "op" => "execute", "proposal_id" => proposal_id,
                                       "approve" => true).fetch("value")
    assert_equal "delivered", delivered["dispatch"]
    assert delivered["can_continue"]
  end

  def test_failed_continuation_dispatch_pauses_and_cleans_up_the_run
    first = @driver.state("one", "Open")
    second = @driver.state("two", "Next")
    @driver.observations = [first, first, second, second]
    provider = FakeProvider.new(["a1", 0.9], ["a1", 0.9])
    server = server_seam(provider:)
    decision = server.send(:dispatch, "op" => "preview", "goal" => "Finish").fetch("value")
    server.send(:dispatch, "op" => "execute", "proposal_id" => decision.dig("proposal", "proposal_id"))
    @driver.dispatch_result = { "dispatch" => "not_delivered", "code" => "NO_ACTION" }

    result = server.send(:dispatch, "op" => "continue", "run_id" => decision["run_id"]).fetch("value")
    assert_equal "paused", result["status"]
    assert_equal "not_delivered", result.dig("receipts", 0, "dispatch")
    assert_equal "ArgumentError", server.send(:dispatch, "op" => "continue", "run_id" => decision["run_id"])["class"]
  end

  def test_terminal_verification_failure_stops_continuation_after_one_dispatch
    first = @driver.state("one", "Open")
    second = @driver.state("two", "Next")
    lost = Wrangle::ScopeLost.new("window gone")
    @driver.observations = [first, first, second, second, lost]
    provider = FakeProvider.new(["a1", 0.9], ["a1", 0.9])
    server = server_seam(provider:)
    decision = server.send(:dispatch, "op" => "preview", "goal" => "Finish").fetch("value")
    server.send(:dispatch, "op" => "execute", "proposal_id" => decision.dig("proposal", "proposal_id"))

    result = server.send(:dispatch, "op" => "continue", "run_id" => decision["run_id"]).fetch("value")
    assert_equal "terminal", result["status"]
    assert result.dig("receipts", 0, "terminal")
    assert_match(/ScopeLost/, result.dig("receipts", 0, "verification_error"))
  end

  def test_failed_autonomous_dispatch_terminates_only_the_run
    state = @driver.state("one", "Open")
    @driver.observations = [state, state]
    @driver.dispatch_result = { "dispatch" => "not_delivered", "code" => "NO_ACTION" }
    server = server_seam(provider: FakeProvider.new(["a1", 0.9]))
    decision = server.send(:dispatch, "op" => "preview", "goal" => "Open").fetch("value")

    receipt = server.send(:dispatch, "op" => "execute",
                                     "proposal_id" => decision.dig("proposal", "proposal_id")).fetch("value")
    refute receipt["can_continue"]
    assert_equal decision["run_id"], receipt["run_id"]
    assert_equal "ArgumentError", server.send(:dispatch, "op" => "continue", "run_id" => decision["run_id"])["class"]
    assert server.send(:dispatch, "op" => "observe")["ok"]
  end

  def test_unqualified_provider_can_assess_but_cannot_dispatch
    state = @driver.state("one", "Open")
    @driver.observations = [state]
    provider = FakeProvider.new(["a1", 0.9], qualified: false)
    server = server_seam(provider:)
    decision = server.send(:dispatch, "op" => "preview", "goal" => "Open").fetch("value")
    refute decision.dig("proposal", "policy", "provider_qualified")

    receipt = server.send(:dispatch, "op" => "execute",
                                     "proposal_id" => decision.dig("proposal", "proposal_id")).fetch("value")
    assert_equal "refused", receipt["dispatch"]
    assert_equal "provider_not_qualified", receipt["reason"]
    assert_equal decision["run_id"], receipt["run_id"]
    refute receipt["can_continue"]
    assert_equal "ArgumentError", server.send(:dispatch, "op" => "continue", "run_id" => decision["run_id"])["class"]
    assert_nil @driver.executed
  end

  def test_preview_and_execute_use_a_revision_bound_one_shot_proposal
    before = @driver.state("one", "Open")
    after = @driver.state("two", "Close")
    @driver.observations = [before, before, after]
    server = server_seam
    server.send(:dispatch, "op" => "observe")

    proposal = server.send(:dispatch, "op" => "preview", "ref" => 1).fetch("value")
    assert_equal "wrangle.proposal.v1", proposal["schema"]
    assert_equal "PRESS", proposal.dig("action", "operation")
    refute proposal.dig("policy", "consequential")

    receipt = server.send(:dispatch, "op" => "execute",
                                     "proposal_id" => proposal["proposal_id"]).fetch("value")
    assert_equal "delivered", receipt["dispatch"]
    assert_equal "verified", receipt["effect"]
    assert_equal({ operation: "PRESS", ref: "@s:e1", text: nil }, @driver.executed)
    assert_equal 1, server.send(:dispatch, "op" => "status").dig("value", "actions_taken")

    consumed = server.send(:dispatch, "op" => "execute", "proposal_id" => proposal["proposal_id"])
    refute consumed["ok"]
    assert_match(/consumed/, consumed["error"])
  end

  def test_unrelated_revision_change_does_not_verify_a_press_effect
    before = @driver.state("one", "Open")
    unrelated = @driver.state("two", "Open")
    unrelated["tree"] = {
      "role" => "window", "name" => "Fixture", "children" => [
        { "role" => "button", "name" => "Open", "states" => ["enabled"], "operations" => ["PRESS"] },
        { "role" => "statictext", "name" => "Unrelated status changed" }
      ]
    }
    @driver.observations = [before, before, unrelated]
    server = server_seam
    server.send(:dispatch, "op" => "observe")
    proposal = server.send(:dispatch, "op" => "preview", "ref" => 1).fetch("value")

    receipt = server.send(:dispatch, "op" => "execute",
                                     "proposal_id" => proposal["proposal_id"]).fetch("value")

    assert_equal "delivered", receipt["dispatch"]
    assert_equal "unchanged", receipt["effect"]
  end

  def test_partial_observation_requires_drill_and_dispatches_the_fresh_ref
    partial = @driver.state("top", "Group", operations: %w[DRILL PRESS], truncated: true)
    detail = @driver.state("detail", "Open", ref: "@old:e1")
    fresh = @driver.state("detail", "Open", ref: "@fresh:e1")
    after = @driver.state("after", "Close")
    @driver.observations = [partial, detail, fresh, after]
    server = server_seam
    server.send(:dispatch, "op" => "observe")

    denied = server.send(:dispatch, "op" => "preview", "ref" => 1)
    assert_equal "PartialObservation", denied["class"]

    drilled = server.send(:dispatch, "op" => "drill", "ref" => 1).fetch("value")
    assert_equal "detail", drilled["revision"]
    assert_equal({ ref: "@s:e1", snapshot_id: "snap-top" }, @driver.drilled)
    proposal = server.send(:dispatch, "op" => "preview", "ref" => 1).fetch("value")
    receipt = server.send(:dispatch, "op" => "execute",
                                     "proposal_id" => proposal["proposal_id"]).fetch("value")

    assert_equal "delivered", receipt["dispatch"]
    assert_equal "@fresh:e1", @driver.executed[:ref]
  end

  def test_drill_refuses_a_leaf
    server = server_seam
    server.send(:dispatch, "op" => "observe")

    reply = server.send(:dispatch, "op" => "drill", "ref" => 1)
    assert_equal "ArgumentError", reply["class"]
    assert_nil @driver.drilled
  end

  def test_preview_and_drill_refuse_indistinguishable_candidates
    state = @driver.state("same", "Open")
    duplicate = state["candidates"].first.merge("ref" => "@s:e2")
    state["candidates"] << duplicate
    state["coverage"]["candidate_count"] = 2
    @driver.observations = [state]
    server = server_seam
    observed = server.send(:dispatch, "op" => "observe").fetch("value")

    preview = server.send(:dispatch, "op" => "preview", "ref" => 1, "operation" => "PRESS")
    assert_equal "ArgumentError", preview["class"]
    assert_match(/multiple visible candidates/, preview["error"])
    assert_equal 0, server.send(:dispatch, "op" => "status").dig("value", "pending_proposals")
    assert_equal 2, observed["candidates"].length

    state["candidates"].each { |candidate| candidate["operations"] = ["DRILL"] }
    drilled = server.send(:dispatch, "op" => "drill", "ref" => 1)
    assert_equal "ArgumentError", drilled["class"]
    assert_match(/multiple visible candidates/, drilled["error"])
    assert_nil @driver.drilled
  end

  def test_revalidation_ambiguity_consumes_the_proposal_and_poison_scope
    before = @driver.state("one", "Open")
    ambiguous = @driver.state("one", "Open").merge("candidates" => [])
    @driver.observations = [before, ambiguous]
    server = server_seam
    server.send(:dispatch, "op" => "observe")
    proposal = server.send(:dispatch, "op" => "preview", "ref" => 1).fetch("value")

    reply = server.send(:dispatch, "op" => "execute", "proposal_id" => proposal["proposal_id"])
    assert_equal "ScopeLost", reply["class"]
    assert reply["terminal"]
    assert_nil @driver.executed
    assert server.send(:dispatch, "op" => "observe")["terminal"]
  end

  def test_revalidation_refuses_a_new_duplicate_even_when_the_revision_is_unchanged
    before = @driver.state("one", "Open")
    duplicate = before["candidates"].first.merge("ref" => "@fresh:e2")
    ambiguous = before.merge("candidates" => [before["candidates"].first.merge("ref" => "@fresh:e1"), duplicate])
    @driver.observations = [before, ambiguous]
    server = server_seam
    server.send(:dispatch, "op" => "observe")
    proposal = server.send(:dispatch, "op" => "preview", "ref" => 1).fetch("value")

    reply = server.send(:dispatch, "op" => "execute", "proposal_id" => proposal["proposal_id"])

    assert_equal "ScopeLost", reply["class"]
    assert reply["terminal"]
    assert_nil @driver.executed
  end

  def test_not_delivered_or_refused_dispatch_is_not_counted_or_verified
    %w[not_delivered refused].each do |dispatch|
      state = @driver.state("one", "Open")
      @driver.observations = [state, state]
      @driver.dispatch_result = { "dispatch" => dispatch, "code" => "NO_ACTION" }
      server = server_seam
      server.send(:dispatch, "op" => "observe")
      proposal = server.send(:dispatch, "op" => "preview", "ref" => 1).fetch("value")

      receipt = server.send(:dispatch, "op" => "execute",
                                       "proposal_id" => proposal["proposal_id"]).fetch("value")
      assert_equal dispatch, receipt["dispatch"]
      assert_equal "not_applicable", receipt["effect"]
      assert_equal 0, server.send(:dispatch, "op" => "status").dig("value", "actions_taken")
    end
  end

  def test_verification_scope_loss_is_reported_without_retry
    before = @driver.state("one", "Open")
    @driver.observations = [before, before, Wrangle::ScopeLost.new("window gone")]
    server = server_seam
    server.send(:dispatch, "op" => "observe")
    proposal = server.send(:dispatch, "op" => "preview", "ref" => 1).fetch("value")

    receipt = server.send(:dispatch, "op" => "execute",
                                     "proposal_id" => proposal["proposal_id"]).fetch("value")
    assert_equal "delivered", receipt["dispatch"]
    assert_equal "unverified", receipt["effect"]
    assert_match(/ScopeLost/, receipt["verification_error"])
    assert receipt["terminal"]
  end

  def test_effect_verification_handles_unchanged_missing_clear_and_toggle_states
    before = @driver.state("same", "Field", role: "textfield", value: "old",
                                            operations: %w[SET_TEXT CLEAR])
    proposal = { "operation" => "SET_TEXT", "text" => "new", "candidate" => before["candidates"].first }
    assert_equal "unverified", Wrangle::DesktopEffect.verify(proposal, before, nil)
    assert_equal "unverified", Wrangle::DesktopEffect.verify({ "operation" => "PRESS" }, before, before)
    pressed = @driver.state("press", "Open")
    press = { "operation" => "PRESS", "candidate" => pressed["candidates"].first }
    assert_equal "unchanged", Wrangle::DesktopEffect.verify(press, pressed, pressed)

    missing = @driver.state("new", "Other", role: "textfield", value: "new",
                                            operations: %w[SET_TEXT CLEAR])
    assert_equal "unverified", Wrangle::DesktopEffect.verify(proposal, before, missing)
    changed = @driver.state("new", "Field", role: "textfield", value: "new",
                                            operations: %w[SET_TEXT CLEAR])
    assert_equal "verified", Wrangle::DesktopEffect.verify(proposal, before, changed)
    assert_equal "unchanged", Wrangle::DesktopEffect.verify(proposal, before, before)

    cleared = @driver.state("new", "Field", role: "textfield", value: "", operations: %w[SET_TEXT CLEAR])
    clear = proposal.merge("operation" => "CLEAR", "text" => nil)
    assert_equal "verified", Wrangle::DesktopEffect.verify(clear, before, cleared)
    contenteditable_blank = @driver.state("new", "Field", role: "textfield", value: "\n",
                                                          operations: %w[SET_TEXT CLEAR])
    assert_equal "verified", Wrangle::DesktopEffect.verify(clear, before, contenteditable_blank)
    assert_equal "unchanged", Wrangle::DesktopEffect.verify(clear, before, before)

    toggle_before = @driver.state("one", "Choice", role: "checkbox", states: ["enabled"], operations: ["TOGGLE"])
    toggle_after = @driver.state("two", "Choice", role: "checkbox", states: %w[enabled checked],
                                                  operations: ["TOGGLE"])
    toggle = { "operation" => "TOGGLE", "candidate" => toggle_before["candidates"].first }
    assert_equal "verified", Wrangle::DesktopEffect.verify(toggle, toggle_before, toggle_after)
    assert_equal "unchanged", Wrangle::DesktopEffect.verify(toggle, toggle_before, toggle_before)
  end

  def test_optional_logging_can_be_disabled_without_changing_safety
    state = @driver.state("one", "Open")
    @driver.observations = [state, state, state]
    server = server_seam(log: nil)
    server.send(:dispatch, "op" => "observe")
    proposal = server.send(:dispatch, "op" => "preview", "ref" => 1).fetch("value")
    assert server.send(:dispatch, "op" => "execute", "proposal_id" => proposal["proposal_id"])["ok"]
    refute server.send(:dispatch, "op" => "unknown")["ok"]
    server.send(:shutdown)
  end

  def test_stale_proposal_is_not_dispatched
    @driver.observations = [@driver.state("one", "Open"), @driver.state("two", "Open")]
    server = server_seam
    server.send(:dispatch, "op" => "observe")
    proposal = server.send(:dispatch, "op" => "preview", "ref" => 1).fetch("value")

    receipt = server.send(:dispatch, "op" => "execute",
                                     "proposal_id" => proposal["proposal_id"]).fetch("value")
    assert_equal "not_delivered", receipt["dispatch"]
    assert_equal "stale_observation", receipt["reason"]
    assert_nil @driver.executed
  end

  def test_consequential_proposal_waits_for_explicit_approval
    state = @driver.state("one", "Send")
    @driver.observations = [state, state, @driver.state("two", "Sent")]
    server = server_seam
    server.send(:dispatch, "op" => "observe")
    proposal = server.send(:dispatch, "op" => "preview", "ref" => 1).fetch("value")
    assert proposal.dig("policy", "consequential")

    paused = server.send(:dispatch, "op" => "execute",
                                    "proposal_id" => proposal["proposal_id"]).fetch("value")
    assert_equal "refused", paused["dispatch"]
    assert_equal "approval_required", paused["reason"]
    assert_nil @driver.executed

    receipt = server.send(:dispatch, "op" => "execute", "proposal_id" => proposal["proposal_id"],
                                     "approve" => true).fetch("value")
    assert_equal "delivered", receipt["dispatch"]
  end

  def test_text_is_exact_but_not_echoed_in_the_proposal
    before = @driver.state("one", "Message", role: "textfield", value: "",
                                             operations: %w[SET_TEXT CLEAR PRESS])
    after = @driver.state("two", "Message", role: "textfield", value: "alpha — 🚜",
                                            operations: %w[SET_TEXT CLEAR PRESS])
    @driver.observations = [before, before, after]
    server = server_seam
    server.send(:dispatch, "op" => "observe")
    proposal = server.send(:dispatch, "op" => "preview", "ref" => 1,
                                      "operation" => "SET_TEXT", "text" => "alpha — 🚜").fetch("value")

    assert_equal({ "source" => "explicit", "characters" => 9 }, proposal.dig("action", "text"))
    refute_includes JSON.generate(proposal), "alpha"
    receipt = server.send(:dispatch, "op" => "execute",
                                     "proposal_id" => proposal["proposal_id"]).fetch("value")
    assert_equal "verified", receipt["effect"]
    events = @log.events.map { |event| event["event"] }
    assert_equal %w[observe preview execute], events
    refute_includes JSON.generate(@log.events), "alpha"
  end

  def test_credentials_and_invalid_action_shapes_fail_before_proposal
    credential = @driver.state("one", "Password", role: "textfield", value: "",
                                                  operations: %w[SET_TEXT CLEAR PRESS])
    @driver.observations = [credential]
    server = server_seam
    server.send(:dispatch, "op" => "observe")

    denied = server.send(:dispatch, "op" => "preview", "ref" => 1,
                                    "operation" => "SET_TEXT", "text" => "secret")
    assert_equal "PolicyDenied", denied["class"]
    assert_empty server.instance_variable_get(:@proposals)

    assert_equal "ArgumentError", server.send(:dispatch, "op" => "preview", "ref" => 2)["class"]
    assert_equal "ArgumentError", server.send(:dispatch, "op" => "preview", "ref" => 1)["class"]
    assert_equal "ArgumentError", server.send(:dispatch, "op" => "preview", "ref" => 1,
                                                         "operation" => "TOGGLE")["class"]
    assert_equal "ArgumentError", server.send(:dispatch, "op" => "preview", "ref" => 1,
                                                         "operation" => "SET_TEXT", "text" => "")["class"]
    assert_equal "ArgumentError", server.send(:dispatch, "op" => "preview", "ref" => 1,
                                                         "operation" => "PRESS", "text" => "no")["class"]
  end

  def test_unknown_delivery_is_terminal_even_when_effect_is_verified
    before = @driver.state("one", "Message", role: "textfield", value: "",
                                             operations: %w[SET_TEXT CLEAR PRESS])
    after = @driver.state("two", "Message", role: "textfield", value: "exact",
                                            operations: %w[SET_TEXT CLEAR PRESS])
    @driver.observations = [before, before, after]
    @driver.dispatch_result = { "dispatch" => "delivery_unknown", "code" => "TIMEOUT" }
    server = server_seam
    server.send(:dispatch, "op" => "observe")
    proposal = server.send(:dispatch, "op" => "preview", "ref" => 1,
                                      "operation" => "SET_TEXT", "text" => "exact").fetch("value")
    receipt = server.send(:dispatch, "op" => "execute",
                                     "proposal_id" => proposal["proposal_id"]).fetch("value")

    assert_equal "delivery_unknown", receipt["dispatch"]
    assert_equal "verified", receipt["effect"]
    assert receipt["terminal"]
    assert_nil @registry.dispatch_finished
    assert server.send(:dispatch, "op" => "observe")["terminal"]
  end

  def test_interrupted_dispatch_is_terminal_and_keeps_the_durable_marker
    before = @driver.state("one", "Open")
    @driver.observations = [before, before]
    @driver.execute_failure = RuntimeError.new("process died")
    server = server_seam
    server.send(:dispatch, "op" => "observe")
    proposal = server.send(:dispatch, "op" => "preview", "ref" => 1).fetch("value")

    reply = server.send(:dispatch, "op" => "execute", "proposal_id" => proposal["proposal_id"])

    assert_equal "DeliveryUnknown", reply["class"]
    assert reply["terminal"]
    assert_equal proposal["proposal_id"], @registry.dispatch_started[:proposal_id]
    assert_nil @registry.dispatch_finished
    assert_empty server.instance_variable_get(:@proposals)
  end

  def test_proposal_cannot_cross_scope_identity
    server = server_seam
    server.send(:dispatch, "op" => "observe")
    proposal = server.send(:dispatch, "op" => "preview", "ref" => 1).fetch("value")
    stored = server.instance_variable_get(:@proposals).fetch(proposal["proposal_id"])
    stored["scope_id"] = "another-scope"

    reply = server.send(:dispatch, "op" => "execute", "proposal_id" => proposal["proposal_id"])
    assert_equal "ScopeLost", reply["class"]
    assert reply["terminal"]
    assert_nil @driver.executed
  end

  def test_expired_proposal_is_consumed_without_dispatch
    server = server_seam
    server.send(:dispatch, "op" => "observe")
    proposal = server.send(:dispatch, "op" => "preview", "ref" => 1).fetch("value")
    stored = server.instance_variable_get(:@proposals).fetch(proposal["proposal_id"])
    stored["created_at"] -= Wrangle::DesktopSessionServer::PROPOSAL_TTL + 1

    receipt = server.send(:dispatch, "op" => "execute",
                                     "proposal_id" => proposal["proposal_id"]).fetch("value")
    assert_equal "proposal_expired", receipt["reason"]
    assert_nil @driver.executed
  end

  def test_malformed_and_unknown_requests_are_refused
    server = server_seam

    assert_equal "bad", server.send(:parse, "not json")["op"]
    reply = server.send(:dispatch, "op" => "wat")
    refute reply["terminal"]
    assert_equal "ArgumentError", reply["class"]
  end

  private

  def serving
    server = Wrangle::DesktopSessionServer.new(
      @socket, {}, driver: @driver, scope: self.class.scope, registry: @registry, log: @log
    )
    @thread = Thread.new { server.run }
    @thread.report_on_exception = false
    wait_for_socket
    Wrangle::SessionClient.new(@socket)
  end

  def server_seam(log: @log, provider: nil)
    Wrangle::DesktopSessionServer.new(
      @socket, {}, driver: @driver, scope: self.class.scope, registry: @registry, log:, provider:
    )
  end

  def wait_for_socket
    sleep 0.01 until File.socket?(@socket)
  end
end
