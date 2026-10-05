# frozen_string_literal: true

require "socket"

require_relative "test_helper"
require_relative "desktop_session_server_test"

# One consequential proposal parked by `task`, resolved by exactly one bound approve or decline.
# Everything here runs in-process against the fake driver; no Mac and no AX session.
class DesktopBoundApprovalTest < Minitest::Test
  FakeProvider = DesktopSessionServerTest::FakeProvider
  FakeLog = DesktopSessionServerTest::FakeLog
  FakeRegistry = DesktopSessionServerTest::FakeRegistry

  # A driver that can report a locked console session, as MacOSDriver#doctor does.
  class LockableDriver < DesktopSessionServerTest::FakeDriver
    attr_accessor :locked
    attr_reader :doctor_calls

    def doctor
      @doctor_calls = (@doctor_calls || 0) + 1
      { "ready" => !locked, "session_locked" => locked == true }
    end
  end

  def setup
    @directory = Dir.mktmpdir("wrangle-bound-approval")
    @socket = File.join(@directory, "task-fixture.sock")
    @driver = LockableDriver.new
    @driver.observations = [@driver.state("one", "Send")]
    @registry = FakeRegistry.new
    @log = FakeLog.new
  end

  def teardown
    @thread&.kill
    @thread&.join
    FileUtils.remove_entry(@directory) if File.directory?(@directory)
  end

  def test_task_parks_the_proposal_with_a_tool_facing_binding
    server, result = parked_task

    assert_equal "approval_required", result["status"]
    binding = result.fetch("binding")
    assert_equal %w[proposal_id revision scope_id ttl_seconds], binding.keys.sort
    assert_equal "scope-1", binding["scope_id"]
    assert_equal "one", binding["revision"]
    assert_equal 300, binding["ttl_seconds"]
    assert_equal "Send", result.dig("pending_action", "label")
    refute(result["pending_action"].keys.intersect?(%w[proposal_id scope_id revision]))
    refute_includes JSON.generate(result), "resume_token"

    assert_nil @driver.executed
    refute @driver.closed, "a parked approval keeps the driver"
    assert_nil @registry.released, "a parked approval keeps the exclusive lease"
    assert_equal 1, status(server)["pending_proposals"]
  end

  def test_parked_binding_names_the_socket_session
    server = Wrangle::DesktopSessionServer.new(
      @socket, {}, driver: @driver, scope: DesktopSessionServerTest.scope, registry: @registry,
                   log: @log, provider: FakeProvider.new(["a1", 0.9])
    )
    result = server.run_task("goal" => "Send it")

    assert_equal "task-fixture", result.dig("binding", "session")
  end

  def test_approve_delivers_once_and_returns_receipt_and_evidence_separately
    server, result = parked_task
    reply = call(server, approve_request(result))

    assert reply["ok"]
    value = reply["value"]
    receipt = value.fetch("receipt")
    assert_equal "wrangle.receipt.v1", receipt["schema"]
    assert_equal "delivered", receipt["dispatch"]
    refute receipt.key?("status"), "the receipt carries no agent-facing status"
    evidence = value.fetch("evidence")
    assert_equal "bounded", evidence["selection"]
    assert_operator evidence["items"].length, :<=, Wrangle::DesktopSessionAutonomy::TASK_EVIDENCE_ITEMS
    refute value.key?("status")

    assert_equal({ operation: "PRESS", ref: "@s:e1", text: nil }, @driver.executed)
    assert_equal result.dig("binding", "proposal_id"), @registry.dispatch_started[:proposal_id]
    refute_includes @registry.dispatch_started.keys, :label
    refute_nil @registry.dispatch_finished
    refute_nil @registry.released, "resolution releases the lease"
    assert @driver.closed

    again = call(server, approve_request(result)).fetch("value")
    assert_equal approval("approval_lost", "consumed", false), again.slice("schema", "status", "reason", "retryable")
  end

  def test_non_true_approve_is_a_request_refusal_that_keeps_the_binding
    server, result = parked_task
    [false, nil, "true", 1].each do |value|
      reply = call(server, approve_request(result).merge("approve" => value))
      refute reply["ok"]
      assert_equal "ArgumentError", reply["class"]
      assert_match(/approve: true/, reply["error"])
    end
    missing = call(server, approve_request(result).except("approve"))
    assert_equal "ArgumentError", missing["class"]

    assert_nil @driver.executed
    assert_nil @registry.dispatch_started
    assert_nil @registry.released
    assert_equal 1, status(server)["pending_proposals"]
    assert_equal "delivered", call(server, approve_request(result)).dig("value", "receipt", "dispatch")
  end

  def test_approval_cannot_rewrite_the_stored_action
    server, result = parked_task
    { "operation" => "SET_TEXT", "ref" => 2, "text" => "other", "label" => "Delete",
      "candidate" => { "label" => "Delete" } }.each do |field, value|
      reply = call(server, approve_request(result).merge(field => value))
      assert_equal "ArgumentError", reply["class"], field
      assert_match(/cannot rewrite/, reply["error"])
    end

    assert_nil @driver.executed
    assert_equal 1, status(server)["pending_proposals"]
  end

  def test_decline_spends_the_proposal_without_touching_the_driver
    server, result = parked_task
    with_approve = call(server, decline_request(result).merge("approve" => false))
    assert_equal "ArgumentError", with_approve["class"]
    assert_equal 1, status(server)["pending_proposals"]

    receipt = call(server, decline_request(result)).fetch("value")
    assert_equal "wrangle.receipt.v1", receipt["schema"]
    assert_equal "refused", receipt["dispatch"]
    assert_equal "not_applicable", receipt["effect"]
    assert_equal "declined", receipt["reason"]
    assert_equal "spent", receipt["approval"]
    refute_equal "approval_required", receipt["status"]
    refute_equal "approval_required", receipt["reason"]

    assert_nil @driver.executed
    assert_nil @registry.dispatch_started
    refute_nil @registry.released
    consumed = call(server, approve_request(result)).fetch("value")
    assert_equal "consumed", consumed["reason"]
  end

  def test_stale_revision_spends_the_approval_without_poisoning
    server, result = parked_task
    @driver.observations = [@driver.state("two", "Send")]

    value = call(server, approve_request(result)).fetch("value")
    expected = approval("approval_lost", "stale_target", false)
    assert_equal expected, value.slice("schema", "status", "reason", "retryable")
    assert_equal result.dig("binding", "proposal_id"), value["proposal_id"]
    assert_equal "scope-1", value["scope_id"]
    assert_equal "one", value["revision"]
    refute value.key?("resume_token")

    assert_nil @driver.executed
    assert_nil @registry.dispatch_started
    refute status(server)["poisoned"]
    refute_nil @registry.released
    assert_equal "consumed", call(server, approve_request(result)).dig("value", "reason")
  end

  def test_changed_gone_or_ambiguous_target_is_stale_not_lost_scope
    {
      "changed" => ->(driver) { driver.state("one", "Send later") },
      "gone" => ->(driver) { driver.state("one", "Send").merge("candidates" => []) },
      "not offered" => ->(driver) { driver.state("one", "Send", operations: ["DRILL"]) },
      "ambiguous" => lambda do |driver|
        state = driver.state("one", "Send")
        state.merge("candidates" => state["candidates"] * 2)
      end
    }.each do |name, fresh|
      @driver = LockableDriver.new
      @driver.observations = [@driver.state("one", "Send")]
      @registry = FakeRegistry.new
      server, result = parked_task
      @driver.observations = [fresh.call(@driver)]

      value = call(server, approve_request(result)).fetch("value")
      assert_equal "stale_target", value["reason"], name
      refute status(server)["poisoned"], name
      assert_nil @driver.executed, name
      assert_nil @registry.dispatch_started, name
    end
  end

  def test_stale_native_ref_during_revalidation_is_stale_target
    server, result = parked_task
    @driver.observations = [Wrangle::DriverRefusal.new("STALE_REF", "gone", delivery: "not_delivered")]

    value = call(server, approve_request(result)).fetch("value")
    assert_equal "stale_target", value["reason"]
    refute status(server)["poisoned"]
  end

  def test_lost_scope_poisons_spends_and_releases_without_a_substitute
    server, result = parked_task
    @driver.observations = [Wrangle::ScopeLost.new("window changed")]

    value = call(server, approve_request(result)).fetch("value")
    assert_equal approval("approval_lost", "lost_scope", false), value.slice("schema", "status", "reason", "retryable")
    assert status(server)["poisoned"]
    assert_nil @driver.executed
    assert_nil @registry.dispatch_started
    refute_nil @registry.released
    assert_equal "consumed", call(server, approve_request(result)).dig("value", "reason")

    @driver = LockableDriver.new
    @driver.observations = [@driver.state("one", "Send")]
    @registry = FakeRegistry.new
    server, result = parked_task
    @driver.observations = [Wrangle::DriverRefusal.new("scope_changed", "replaced", delivery: "not_delivered")]
    assert_equal "lost_scope", call(server, approve_request(result)).dig("value", "reason")
    assert status(server)["poisoned"]
  end

  def test_proposal_bound_to_another_scope_is_lost_scope
    server, result = parked_task
    stored = server.instance_variable_get(:@proposals).fetch(result.dig("binding", "proposal_id"))
    stored["scope_id"] = "scope-other"

    value = call(server, approve_request(result).merge("scope_id" => "scope-other")).fetch("value")
    assert_equal "lost_scope", value["reason"]
    assert status(server)["poisoned"]
  end

  def test_unknown_id_and_mismatched_binding_do_not_spend
    server, result = parked_task

    unknown = call(server, approve_request(result).merge("proposal_id" => "nope")).fetch("value")
    assert_equal approval("approval_lost", "unknown", false), unknown.slice("schema", "status", "reason", "retryable")
    wrong_scope = call(server, approve_request(result).merge("scope_id" => "scope-2")).fetch("value")
    assert_equal "unknown", wrong_scope["reason"]
    wrong_revision = call(server, approve_request(result).merge("revision" => "two")).fetch("value")
    assert_equal "unknown", wrong_revision["reason"]
    declined_wrong = call(server, decline_request(result).merge("revision" => "two")).fetch("value")
    assert_equal "unknown", declined_wrong["reason"]

    refute status(server)["poisoned"]
    assert_nil @registry.released
    assert_equal 1, status(server)["pending_proposals"]
    assert_equal "delivered", call(server, approve_request(result)).dig("value", "receipt", "dispatch")
  end

  def test_expired_binding_is_spent_without_dispatch
    server, result = parked_task
    age(server, result, Wrangle::DesktopProposal::TTL + 1)

    value = call(server, approve_request(result)).fetch("value")
    assert_equal approval("approval_expired", "expired", false), value.slice("schema", "status", "reason", "retryable")
    assert_nil @driver.executed
    assert_nil @registry.dispatch_started
    refute_nil @registry.released
    assert_equal "consumed", call(server, decline_request(result)).dig("value", "reason")
  end

  def test_locked_session_keeps_the_same_binding_until_the_ttl
    server, result = parked_task
    @driver.locked = true

    value = call(server, approve_request(result)).fetch("value")
    expected = approval("session_locked", "session_locked", true)
    assert_equal expected, value.slice("schema", "status", "reason", "retryable")
    assert_equal result.dig("binding", "proposal_id"), value["proposal_id"]
    assert_nil @driver.executed
    assert_nil @registry.dispatch_started, "no durable marker while locked"
    assert_nil @registry.released
    assert_equal 1, status(server)["pending_proposals"]

    @driver.locked = false
    assert_equal "delivered", call(server, approve_request(result)).dig("value", "receipt", "dispatch")
  end

  def test_locked_session_past_the_ttl_becomes_expired
    server, result = parked_task
    @driver.locked = true
    assert_equal "session_locked", call(server, approve_request(result)).dig("value", "status")
    age(server, result, Wrangle::DesktopProposal::TTL + 1)

    value = call(server, approve_request(result)).fetch("value")
    assert_equal "approval_expired", value["status"]
    assert_nil @registry.dispatch_started
  end

  def test_lock_found_after_the_marker_is_not_a_second_chance
    server, result = parked_task
    @driver.dispatch_result = { "dispatch" => "not_delivered", "code" => "session_locked" }

    receipt = call(server, approve_request(result)).dig("value", "receipt")
    assert_equal "not_delivered", receipt["dispatch"]
    assert_equal "session_locked", receipt["reason"]
    refute_nil @registry.dispatch_finished
    assert_equal "consumed", call(server, approve_request(result)).dig("value", "reason")
  end

  def test_unqualified_provider_is_refused_and_spent_without_dispatch
    server, result = parked_task(provider: FakeProvider.new(["a1", 0.9], qualified: false))
    assert_equal "approval_required", result["status"]

    receipt = call(server, approve_request(result)).dig("value", "receipt")
    assert_equal "refused", receipt["dispatch"]
    assert_equal "provider_not_qualified", receipt["reason"]
    assert_equal "spent", receipt["approval"]
    assert_nil @driver.executed
    assert_nil @registry.dispatch_started
  end

  def test_only_consequential_proposals_are_eligible
    server = seam
    server.send(:dispatch, "op" => "observe")
    @driver.observations = [@driver.state("one", "Open")]
    server.send(:dispatch, "op" => "observe")
    proposal = server.send(:dispatch, "op" => "preview", "ref" => 1).fetch("value")
    request = { "op" => "approve", "proposal_id" => proposal["proposal_id"], "scope_id" => proposal["scope_id"],
                "revision" => proposal["revision"], "approve" => true }

    reply = call(server, request)
    assert_equal "ArgumentError", reply["class"]
    assert_nil @driver.executed
  end

  def test_execute_op_keeps_poisoning_on_ambiguous_revalidation
    server = seam
    server.send(:dispatch, "op" => "observe")
    proposal = server.send(:dispatch, "op" => "preview", "ref" => 1).fetch("value")
    state = @driver.state("one", "Send")
    @driver.observations = [state.merge("candidates" => state["candidates"] * 2)]

    reply = server.send(:dispatch, "op" => "execute", "proposal_id" => proposal["proposal_id"], "approve" => true)
    assert_equal "ScopeLost", reply["class"]
    assert status(server)["poisoned"]
  end

  def test_non_task_session_keeps_its_lease_after_resolution
    server = seam
    server.send(:dispatch, "op" => "observe")
    proposal = server.send(:dispatch, "op" => "preview", "ref" => 1).fetch("value")

    receipt = call(server, { "op" => "decline", "proposal_id" => proposal["proposal_id"],
                             "scope_id" => proposal["scope_id"], "revision" => proposal["revision"] })
    assert_equal "declined", receipt.dig("value", "reason")
    assert_nil @registry.released
    refute @driver.closed
  end

  def test_desktop_task_keeps_the_parked_server_in_process
    task = Wrangle::DesktopTask.new(
      driver: @driver, provider: FakeProvider.new(["a1", 0.9]), registry: @registry, log: @log
    )
    result = task.run(app: "Finder", goal: "Send it")

    assert_equal "approval_required", result["status"]
    refute @driver.closed
    reply = task.server.send(:dispatch, approve_request(result))
    assert_equal "delivered", reply.dig("value", "receipt", "dispatch")
    assert @driver.closed
  end

  def test_parked_socket_serves_until_the_approval_resolves
    server, result = parked_task(socket: @socket)
    ready = Queue.new
    @thread = Thread.new { server.serve_parked_approval(ready: -> { ready << true }) }
    @thread.report_on_exception = false
    ready.pop
    client = Wrangle::SessionClient.new(@socket)

    refused = client.call("approve", **symbolize(approve_request(result).except("op").merge("approve" => false)))
    assert_equal "ArgumentError", refused["class"]
    delivered = client.call("approve", **symbolize(approve_request(result).except("op")))
    assert_equal "delivered", delivered.dig("value", "receipt", "dispatch")

    assert @thread.join(2), "the parked session exits after resolution"
    refute File.exist?(@socket)
    refute File.exist?("#{@socket}.pid")
    refute_nil @registry.released
  end

  def test_parked_socket_expires_at_the_ttl
    server, result = parked_task(socket: @socket)
    age(server, result, Wrangle::DesktopProposal::TTL - 0.2)

    @thread = Thread.new { server.serve_parked_approval }
    @thread.report_on_exception = false
    assert @thread.join(3), "the parked session exits at the TTL"
    refute File.exist?(@socket)
    refute_nil @registry.released
    assert_nil @driver.executed
    assert_equal "consumed", call(server, approve_request(result)).dig("value", "reason")
  end

  def test_task_host_child_writes_one_reply_then_serves
    reader, writer = IO.pipe
    writer.autoclose = false # the child side owns and closes this descriptor
    fake = Object.new
    received = {}
    fake.define_singleton_method(:run) do |**keywords|
      received.merge!(keywords.except(:on_ready))
      keywords[:on_ready].call({ "status" => "approval_required" })
      { "status" => "approval_required" }
    end

    Wrangle::DesktopTaskHost.serve(@socket, JSON.generate("app" => "Finder", "goal" => "Send", "x" => 1),
                                   writer.fileno.to_s, task: fake)
    lines = reader.read.lines
    assert_equal 1, lines.length
    assert_equal({ "ok" => true, "value" => { "status" => "approval_required" } }, JSON.parse(lines.first))
    assert_equal({ app: "Finder", goal: "Send", socket_path: @socket }, received)
  ensure
    reader&.close
  end

  def test_task_host_child_reports_failures_as_one_reply
    reader, writer = IO.pipe
    writer.autoclose = false # the child side owns and closes this descriptor
    fake = Object.new
    fake.define_singleton_method(:run) { |**| raise Wrangle::ScopeLost, "No visible Finder window is available" }

    Wrangle::DesktopTaskHost.serve(@socket, JSON.generate("app" => "Finder", "goal" => "Send"),
                                   writer.fileno.to_s, task: fake)
    reply = JSON.parse(reader.read)
    refute reply["ok"]
    assert_equal "ScopeLost", reply["class"]
  ensure
    reader&.close
  end

  def test_desktop_task_serves_a_parked_socket_and_calls_on_ready
    ready = Queue.new
    thread = Thread.new do
      ready.pop
      client = Wrangle::SessionClient.new(@socket)
      client.call("decline", **symbolize(decline_request(@parked).except("op")))
    end
    thread.report_on_exception = false
    task = Wrangle::DesktopTask.new(
      driver: @driver, provider: FakeProvider.new(["a1", 0.9]), registry: @registry, log: @log
    )
    notify = lambda do |value|
      @parked = value
      ready << true
    end
    result = task.run(app: "Finder", goal: "Send it", socket_path: @socket, on_ready: notify)

    assert_equal "approval_required", result["status"]
    assert thread.join(2)
    refute File.exist?(@socket)
    refute_nil @registry.released
  end

  def test_driver_refusal_after_the_marker_stays_not_delivered
    server, result = parked_task
    @driver.execute_failure = Wrangle::DriverRefusal.new(
      "NO_AX", "ref refused", delivery: "not_delivered"
    )

    receipt = call(server, approve_request(result)).dig("value", "receipt")
    assert_equal "not_delivered", receipt["dispatch"]
    assert_equal "NO_AX", receipt["reason"]
    refute_nil @registry.dispatch_finished
    assert_equal "consumed", call(server, approve_request(result)).dig("value", "reason")
  end

  def test_delivery_unknown_and_interrupted_execute_poison_the_session
    server, result = parked_task
    @driver.execute_failure = Wrangle::DeliveryUnknown.new("maybe delivered")
    reply = call(server, approve_request(result))
    assert_equal "DeliveryUnknown", reply["class"]
    assert status(server)["poisoned"]

    @driver = LockableDriver.new
    @driver.observations = [@driver.state("one", "Send")]
    @registry = FakeRegistry.new
    server, result = parked_task
    @driver.execute_failure = RuntimeError.new("kernel panic")
    reply = call(server, approve_request(result))
    assert_equal "DeliveryUnknown", reply["class"]
    assert status(server)["poisoned"]
  end

  def test_non_stale_driver_refusal_during_observation_propagates
    server, result = parked_task
    @driver.observations = [Wrangle::DriverRefusal.new("TIMEOUT", "slow", delivery: "not_delivered")]
    reply = call(server, approve_request(result))
    assert_equal "DriverRefusal", reply["class"]
    assert_equal 1, status(server)["pending_proposals"]
  end

  def test_doctor_errors_are_treated_as_unlocked
    server, result = parked_task
    @driver.define_singleton_method(:doctor) { raise Wrangle::DriverUnavailable, "helper gone" }
    assert_equal "delivered", call(server, approve_request(result)).dig("value", "receipt", "dispatch")
  end

  def test_task_host_parent_reads_the_child_reply_over_the_pipe
    Dir.mktmpdir("wrangle-host") do |home|
      ENV["WRANGLE_HOME"] = home
      exe = File.join(home, "fake-exe")
      File.write(exe, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        IO.open(Integer(ARGV[3]), "w") do |io|
          io.puts(JSON.generate("ok" => true, "value" => { "status" => "done", "session" => ARGV[1] }))
        end
      RUBY
      File.chmod(0o700, exe)

      reply = Wrangle::DesktopTaskHost.run(
        { "app" => "Finder", "goal" => "Inspect" }, exe:, session: "host-fixture"
      )
      assert reply["ok"]
      assert_equal "done", reply.dig("value", "status")
      assert_includes reply.dig("value", "session"), "host-fixture"
    end
  ensure
    ENV["WRANGLE_HOME"] = nil
  end

  def test_task_host_parent_refuses_an_already_running_session_and_an_empty_child
    Dir.mktmpdir("wrangle-host") do |home|
      ENV["WRANGLE_HOME"] = home
      socket = Wrangle::SessionServer.socket_path("busy")
      FileUtils.mkdir_p(File.dirname(socket))
      server = UNIXServer.new(socket)
      Thread.new do
        client = server.accept
        client.gets
        client.puts(JSON.generate("ok" => true, "value" => { "pid" => Process.pid }))
        client.close
      end
      sleep 0.01 until File.socket?(socket)

      assert_raises(ArgumentError) do
        Wrangle::DesktopTaskHost.run({ "app" => "Finder", "goal" => "x" }, exe: "/bin/true", session: "busy")
      end
      server.close
      FileUtils.rm_f(socket)

      exe = File.join(home, "silent-exe")
      File.write(exe, "#!/usr/bin/env ruby\n# write nothing\n")
      File.chmod(0o700, exe)
      error = assert_raises(Wrangle::Error) do
        Wrangle::DesktopTaskHost.run({ "app" => "Finder", "goal" => "x" }, exe:, session: "silent")
      end
      assert_match(/without a result/, error.message)
    end
  ensure
    ENV["WRANGLE_HOME"] = nil
  end

  private

  def seam(socket: nil, provider: nil)
    Wrangle::DesktopSessionServer.new(
      socket, {}, driver: @driver, scope: DesktopSessionServerTest.scope, registry: @registry,
                  log: @log, provider:
    )
  end

  def parked_task(provider: FakeProvider.new(["a1", 0.9]), socket: nil)
    server = seam(socket:, provider:)
    [server, server.run_task("goal" => "Send it")]
  end

  def approve_request(result)
    binding = result.fetch("binding")
    { "op" => "approve", "proposal_id" => binding["proposal_id"], "scope_id" => binding["scope_id"],
      "revision" => binding["revision"], "approve" => true }
  end

  def decline_request(result) = approve_request(result).except("approve").merge("op" => "decline")

  def approval(status, reason, retryable)
    { "schema" => "wrangle.approval.v1", "status" => status, "reason" => reason, "retryable" => retryable }
  end

  def call(server, request) = server.send(:dispatch, request)
  def status(server) = server.send(:dispatch, "op" => "status").fetch("value")

  def age(server, result, seconds)
    stored = server.instance_variable_get(:@proposals).fetch(result.dig("binding", "proposal_id"))
    stored["created_at"] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - seconds
  end

  def symbolize(hash) = hash.transform_keys(&:to_sym)
end
