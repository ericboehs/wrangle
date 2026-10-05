# frozen_string_literal: true

require "open3"
require "shellwords"
require "test_helper"

# The CLI is the whole interface — an agent is meant to drive Safari by shell command rather than by
# writing Ruby against these classes — so the parts of it that need no Safari to answer are worth
# holding still. `--version` shipped broken: the subcommand existed, the flag everyone actually types
# did not, and nothing noticed until the built gem was run by hand.
class CliTest < Minitest::Test
  parallelize_me!
  EXE = File.expand_path("../exe/wrangle", __dir__)
  LIB = File.expand_path("../lib", __dir__)
  FAKE_MACOS = File.expand_path("fixtures/fake_macos_helper.rb", __dir__)
  FAKE_TART = File.expand_path("fixtures/fake_tart.rb", __dir__)

  def run_cli(*argv, env: {})
    out = IO.popen([env, RbConfig.ruby, "--disable-gems", "-I", LIB, EXE, *argv], err: %i[child out], &:read)
    [out, $CHILD_STATUS.exitstatus]
  end

  def test_every_spelling_of_version_prints_the_version_and_exits_clean
    ["version", "--version", "-v"].each do |spelling|
      out, status = run_cli(spelling)

      assert_equal Wrangle::VERSION, out.strip, "`wrangle #{spelling}` did not print the version"
      assert_equal 0, status
    end
  end

  def test_the_version_is_the_one_the_gem_would_ship
    assert_match(/\A\d+\.\d+\.\d+/, Wrangle::VERSION)
  end

  def test_help_is_offered_for_every_spelling_and_for_no_command_at_all
    [[], ["help"], ["-h"], ["--help"]].each do |argv|
      out, status = run_cli(*argv)

      assert_match(/hand one Safari window to a program/, out)
      assert_equal 0, status, "`wrangle #{argv.join(" ")}` should not be an error"
    end
  end

  # Usage that names neither the flag nor the exit codes leaves the reader to find both by accident.
  def test_help_documents_the_flags_and_exit_codes_it_promises
    out, = run_cli("--help")

    assert_match(/--version/, out)
    assert_match(/Exit codes: 0 ok, 2 usage, 3 stale/, out)
  end

  def test_an_unknown_command_says_so_and_exits_usage
    out, status = run_cli("teleport")

    assert_match(/unknown command: teleport/, out)
    assert_equal 2, status
  end

  def test_macos_window_and_display_discovery
    with_fake_commands do |env|
      out, status = run_cli("windows", "--app", "Finder", env:)
      assert_equal 0, status
      assert_match(/w-1\s+Finder/, out)
      refute_match(/Private title/, out)

      out, status = run_cli("displays", "--driver", "macos", env:)
      assert_equal 0, status
      assert_match(/0\s+x=/, out)
    end
  end

  def test_tart_guest_window_inventory_and_read_only_observation
    with_fake_tart_commands do |env, helper|
      out, status = run_cli(
        "windows", "--vm", "fixture-vm", "--app", "Finder", "--guest-helper", helper, "--json", env:
      )
      windows = JSON.parse(out)
      assert_equal 0, status
      assert_equal "w-1", windows.first["id"]

      out, status = run_cli(
        "tart-observe", "--vm", "fixture-vm", "--app", "Finder",
        "--guest-helper", helper, "--json", env:
      )
      result = JSON.parse(out)
      assert_equal 0, status
      assert_equal "wrangle.tart-guest-observation.v1", result["schema"]
      assert_equal "fixture-vm", result["vm"]
      assert result["read_only"]
      assert_equal "tart_guest", result.dig("observation", "driver")
      assert result.dig("observation", "read_only")
      assert_equal "Native Open", result.dig("observation", "candidates", 0, "label")
    end
  end

  def test_tart_guest_session_is_bound_to_one_app_and_refuses_mutation
    with_fake_tart_commands do |env, helper|
      out, status = run_cli(
        "attach", "--vm", "fixture-vm", "--app", "Finder", "--guest-helper", helper,
        "--session", "guest", "--json", env:
      )
      assert_equal 0, status, out
      observation = JSON.parse(out).fetch("value")
      assert_equal "wrangle.observation.v1", observation["schema"]
      assert_equal "tart_guest", observation["driver"]
      assert observation["read_only"]

      out, status = run_cli("preview", "1", "--session", "guest", "--json", env:)
      assert_equal 0, status
      proposal = JSON.parse(out).dig("value", "proposal_id")

      out, status = run_cli("execute", proposal, "--session", "guest", "--json", env:)
      receipt = JSON.parse(out).fetch("value")
      assert_equal 0, status
      assert_equal "not_delivered", receipt["dispatch"]
      assert_equal "read_only", receipt["reason"]

      _, status = run_cli("close", "--session", "guest", env:)
      assert_equal 0, status
      assert_empty Dir.glob(File.join(env.fetch("WRANGLE_HOME"), "scopes", "*"))
    end
  end

  def test_single_desktop_task_selects_observes_and_releases_the_window
    with_fake_commands do |env|
      trace = File.join(env.fetch("WRANGLE_HOME"), "task-trace.jsonl")
      File.write(trace, JSON.generate(
        "name" => "action",
        "answer" => {
          "choice" => "DONE", "confidence" => 0.91,
          "probabilities" => { "a1" => 0.02, "DONE" => 0.91, "BLOCKED" => 0.04, "HANDOFF" => 0.03 }
        }
      ) << "\n")

      out, status = run_cli(
        "task", "--app", "Finder", "--goal", "Inspect the fixture", "--provider", "replay",
        "--provider-trace", trace, "--json", env:
      )
      reply = JSON.parse(out)

      assert_equal 0, status
      assert reply["ok"]
      assert_equal "wrangle.task.v1", reply.dig("value", "schema")
      assert_equal "done", reply.dig("value", "status")
      assert_equal 0, reply.dig("value", "actions_taken")
      assert reply.dig("value", "root_preserved")
      assert_equal "Native Open", reply.dig("value", "evidence", "items", 0, "label")
      assert_empty Dir.glob(File.join(env.fetch("WRANGLE_HOME"), "scopes", "*"))
    end
  end

  # The real driver path: the CLI parent returns as soon as the task stops for approval, and a child
  # process keeps the session, lease, and in-memory proposal on a socket until one bound request.
  # rubocop:disable-next Metrics/MethodLength
  def test_consequential_task_parks_a_child_session_until_decline
    with_fake_commands(helper_mode: "consequential") do |env|
      trace = File.join(env.fetch("WRANGLE_HOME"), "task-trace.jsonl")
      File.write(trace, JSON.generate(
        "name" => "action",
        "answer" => {
          "choice" => "a1", "confidence" => 0.91,
          "probabilities" => { "a1" => 0.91, "DONE" => 0.03, "BLOCKED" => 0.03, "HANDOFF" => 0.03 }
        }
      ) << "\n")

      out, status = run_cli(
        "task", "--app", "Finder", "--goal", "Send the fixture", "--provider", "replay",
        "--provider-trace", trace, "--json", env:
      )
      reply = JSON.parse(out)
      assert_equal 0, status, out
      value = reply.fetch("value")
      assert_equal "approval_required", value["status"]
      binding = value.fetch("binding")
      assert_equal 300, binding["ttl_seconds"]
      refute_includes JSON.generate(value["pending_action"]), binding["proposal_id"]
      refute_includes out, "resume_token"
      socket = File.join(env.fetch("WRANGLE_HOME"), "#{binding.fetch("session")}.sock")
      assert File.socket?(socket), "the parked child serves the session socket"
      assert_equal 0o600, File.stat(socket).mode & 0o777
      assert_equal 0o700, File.stat(File.dirname(socket)).mode & 0o777
      child_log = File.join(env.fetch("WRANGLE_HOME"), "#{binding.fetch("session")}.log")
      assert_equal 0o600, File.stat(child_log).mode & 0o777
      refute value.key?("decision")
      refute_empty Dir.glob(File.join(env.fetch("WRANGLE_HOME"), "scopes", "*.json"))

      args = ["--session", binding["session"], "--proposal-id", binding["proposal_id"],
              "--scope-id", binding["scope_id"], "--revision", binding["revision"], "--json"]
      wrong, = run_cli("decline", *args.map { |arg| arg == binding["revision"] ? "other" : arg }, env:)
      assert_equal "unknown", JSON.parse(wrong).dig("value", "reason")

      out, status = run_cli("decline", *args, env:)
      receipt = JSON.parse(out).fetch("value")
      assert_equal 0, status, out
      assert_equal "declined", receipt["reason"]
      assert_equal "spent", receipt["approval"]

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      sleep 0.05 while File.exist?(socket) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      refute File.exist?(socket), "the parked child exits once the approval resolves"
      assert_empty Dir.glob(File.join(env.fetch("WRANGLE_HOME"), "scopes", "*.json"))

      # The tool maps this exit 5 to approval_expired.
      out, status = run_cli("approve", *args, env:)
      assert_equal 5, status, out
      assert_match(/No wrangle session/, out)
      logs = Dir.glob(File.join(env.fetch("WRANGLE_HOME"), "logs", "*.jsonl")).map { |path| File.read(path) }.join
      refute_includes logs, binding["proposal_id"]
    end
  end

  def test_bound_approval_commands_need_the_whole_binding
    out, status = run_cli("approve", "--session", "missing", "--proposal-id", "p")
    assert_equal 2, status
    assert_match(/needs --proposal-id, --scope-id, and --revision/, out)

    Dir.mktmpdir("wrangle-cli") do |home|
      out, status = run_cli("decline", "--session", "missing", "--proposal-id", "p", "--scope-id", "s",
                            "--revision", "r", env: { "WRANGLE_HOME" => home })
      assert_equal 5, status
      assert_match(/No wrangle session/, out)
    end
  end

  def test_single_desktop_task_requires_a_natural_goal_and_application
    out, status = run_cli("task", "--app", "Finder", "--json")

    assert_equal 2, status
    assert_match(/needs --app APP and --goal GOAL/, out)
  end

  def test_single_desktop_task_defaults_to_jev_when_no_provider_is_configured
    with_fake_commands do |env|
      out, status = run_cli("task", "--app", "Finder", "--goal", "Inspect it", "--json", env:)
      reply = JSON.parse(out)

      assert_equal 3, status
      refute reply["ok"]
      assert_equal "ConfigurationError", reply["class"]
      assert_match(/Set JEV_API_KEY/, reply["error"])
    end
  end

  def test_single_desktop_task_rejects_an_explicitly_empty_provider
    with_fake_commands do |env|
      env = env.merge("WRANGLE_DESKTOP_PROVIDER" => "")
      out, status = run_cli("task", "--app", "Finder", "--goal", "Inspect it", "--json", env:)
      reply = JSON.parse(out)

      assert_equal 3, status
      refute reply["ok"]
      assert_equal "ConfigurationError", reply["class"]
      assert_match(/WRANGLE_DESKTOP_PROVIDER cannot be empty/, reply["error"])
    end
  end

  def test_doctor_reports_the_ready_native_driver
    with_fake_commands do |env|
      out, status = run_cli("doctor", env:)

      assert_equal 0, status
      assert_match(/ready\s+true/, out)
      assert_match(/driver\s+macos_native/, out)
      assert_match(/display source\s+macos_native/, out)
    end
  end

  def test_macos_session_attaches_observes_inspects_and_closes
    with_fake_commands do |env|
      out, status = run_cli("attach", "w-1", "--app", "Finder", "--session", "desktop-test", env:)
      assert_equal 0, status
      assert_match(/window\s+Finder/, out)
      assert_match(/found 1 possible action/, out)
      assert_match(/press\s+button\s+Native Open/, out)

      out, status = run_cli("inspect", "--session", "desktop-test", "--json", env:)
      assert_equal 0, status
      assert_match(/wrangle\.observation\.v1/, out)

      out, status = run_cli("preview", "1", "--session", "desktop-test", "--json", env:)
      assert_equal 0, status
      proposal_id = JSON.parse(out).dig("value", "proposal_id")
      refute_nil proposal_id

      out, status = run_cli("execute", proposal_id, "--session", "desktop-test", "--json", env:)
      assert_equal 0, status
      assert_equal "delivered", JSON.parse(out).dig("value", "dispatch")

      out, status = run_cli("close", "--session", "desktop-test", env:)
      assert_equal 0, status
      assert_match(/control released; the application window remains open/, out)
    end
  end

  def test_failed_desktop_attach_reports_json_and_releases_the_scope
    with_fake_commands(helper_mode: "snapshot-refusal") do |env|
      out, status = run_cli("attach", "w-1", "--app", "Finder", "--session", "failed-attach", "--json", env:)
      reply = JSON.parse(out)

      assert_equal 3, status
      refute reply["ok"]
      assert_equal "DriverRefusal", reply["class"]
      assert_match(/native snapshot unavailable/, reply["error"])
      refute reply["terminal"]
      refute File.exist?(File.join(env.fetch("WRANGLE_HOME"), "failed-attach.sock"))
      assert_empty Dir.glob(File.join(env.fetch("WRANGLE_HOME"), "scopes", "*"))
    end
  end

  def test_qualification_emits_an_owner_only_replay_receipt
    Dir.mktmpdir("wrangle-qualification") do |directory|
      cases = Wrangle::ProviderQualification.load
      receipt = File.join(directory, "receipt.json")

      out, status = run_cli("qualify", "--provider", "replay", "--output", receipt, "--json")
      report = JSON.parse(out)
      assert_equal 0, status
      assert report["qualified"]
      assert_equal cases.length, report["passed"]
      assert_equal report, JSON.parse(File.read(receipt))
      assert_equal 0o600, File.stat(receipt).mode & 0o777
    end
  end

  def test_qualification_requires_an_explicit_provider
    out, status = run_cli("qualify")

    assert_equal 2, status
    assert_match(/needs --provider/, out)
  end

  def test_explicit_replay_provider_can_propose_but_is_not_silently_qualified
    with_fake_commands do |env|
      trace = File.join(env.fetch("WRANGLE_HOME"), "decisions.jsonl")
      answer = { "choice" => "a1", "confidence" => 0.9,
                 "probabilities" => { "a1" => 0.9, "DONE" => 0.04, "BLOCKED" => 0.03, "HANDOFF" => 0.03 } }
      File.write(trace, JSON.generate("name" => "action", "answer" => answer) << "\n")
      _, status = run_cli("attach", "w-1", "--app", "Finder", "--session", "provider",
                          "--provider", "replay", "--provider-trace", trace, env:)
      assert_equal 0, status

      out, status = run_cli("preview", "--goal", "Open the fixture", "--session", "provider", "--json", env:)
      assert_equal 0, status
      decision = JSON.parse(out).fetch("value")
      assert_equal "PRESS", decision["operation"]
      refute decision.dig("proposal", "policy", "provider_qualified")

      _, status = run_cli("close", "--session", "provider", env:)
      assert_equal 0, status
    end
  end

  def test_emergency_stop_terminates_without_application_focus
    with_fake_commands do |env|
      _, status = run_cli("attach", "w-1", "--app", "Finder", "--session", "emergency", env:)
      assert_equal 0, status

      out, status = run_cli("stop", "--session", "emergency", env:)
      assert_equal 0, status
      assert_match(/in-flight delivery must be treated as unknown/, out)
      refute File.exist?(File.join(env.fetch("WRANGLE_HOME"), "emergency.sock"))
    end
  end

  def test_macos_frontmost_countdown_and_picker_select_a_window
    with_fake_commands do |env|
      out, status = run_cli("attach", "--app", "Finder", "--frontmost", "0", "--session", "front", env:)
      assert_equal 0, status
      assert_match(/window\s+Finder/, out)
      run_cli("close", "--session", "front", env:)

      out, status = run_cli_input("1\n", "attach", "--app", "Finder", "--pick", "--session", "pick", env:)
      assert_equal 0, status
      assert_match(/Window: window\s+Finder/m, out)
      run_cli("close", "--session", "pick", env:)
    end
  end

  def test_help_mentions_stored_ui_skills
    out, status = run_cli("--help")

    assert_equal 0, status
    assert_match(/wrangle skills/, out)
    assert_match(/--teach/, out)
    assert_match(/--no-skill/, out)
  end

  def test_skill_flags_are_usage_errors_until_a_goal_is_present
    out, status = run_cli("run", "--teach", "--no-skill")
    assert_equal 2, status
    assert_match(/needs a goal/, out)

    out, status = run_cli("task", "--teach", "--no-skill", "--json")
    assert_equal 2, status
    assert_match(/needs --app APP and --goal GOAL/, out)
  end

  def test_skills_lists_a_stored_procedure_and_an_empty_store
    Dir.mktmpdir do |dir|
      out, status = run_cli("skills", env: { "WRANGLE_SKILLS_DIR" => dir })
      assert_equal 0, status
      assert_match(/no skills in/, out)

      Wrangle::SkillStore.new(dir:).save(
        Wrangle::UiSkill.build(
          id: "finder-open", version: 1, title: "Open search", summary: "Open the search window.",
          apps: ["Finder"], legs: ["Open Search."], stop: "Search is visible."
        )
      )
      out, status = run_cli("skills", env: { "WRANGLE_SKILLS_DIR" => dir })
      assert_equal 0, status
      assert_match(/finder-open  v1  Open the search window/, out)

      File.write(File.join(dir, "broken.json"), "{")
      out, status = run_cli("skills", "--json", env: { "WRANGLE_SKILLS_DIR" => dir })
      assert_equal 0, status
      payload = JSON.parse(out)
      assert_equal "finder-open", payload.dig("skills", 0, "id")
      assert_equal "invalid json", payload.dig("skipped", 0, "reason")

      out, status = run_cli("skills", env: { "WRANGLE_SKILLS_DIR" => dir })
      assert_equal 0, status
      assert_match(/skipped  broken.json: invalid json/, out)
    end
  end

  def test_a_desktop_task_teaches_a_skill_and_the_next_task_reuses_it
    with_fake_commands do |env|
      dir = File.join(env.fetch("WRANGLE_HOME"), "skills")
      env = env.merge("WRANGLE_SKILLS_DIR" => dir)
      trace = File.join(env.fetch("WRANGLE_HOME"), "task-trace.jsonl")
      write_done_trace(trace)

      out, status = run_cli(
        "task", "--app", "Finder", "--goal", "Inspect the fixture", "--provider", "replay",
        "--provider-trace", trace, "--teach", "--json", env:
      )
      reply = JSON.parse(out)
      assert_equal 0, status, out
      assert_equal "done", reply.dig("value", "status")
      assert_equal false, reply.dig("value", "skill", "applied")
      assert reply.dig("value", "taught", "saved")
      taught_id = reply.dig("value", "taught", "id")
      body = File.read(reply.dig("value", "taught", "path"))
      refute_includes body, "Native Open"
      refute_includes body, "snap-"

      write_done_trace(trace)
      out, status = run_cli(
        "task", "--app", "Finder", "--goal", "Inspect the fixture", "--provider", "replay",
        "--provider-trace", trace, "--json", env:
      )
      reply = JSON.parse(out)
      assert_equal 0, status, out
      assert_equal true, reply.dig("value", "skill", "applied")
      assert_equal "clear", reply.dig("value", "skill", "source")
      assert_equal taught_id, reply.dig("value", "skill", "id")
    end
  end

  def test_a_human_task_reports_the_skill_and_a_save_failure
    with_fake_commands do |env|
      dir = File.join(env.fetch("WRANGLE_HOME"), "skills")
      env = env.merge("WRANGLE_SKILLS_DIR" => dir)
      trace = File.join(env.fetch("WRANGLE_HOME"), "human-trace.jsonl")
      write_done_trace(trace)
      out, status = run_cli(
        "task", "--app", "Finder", "--goal", "Inspect the fixture", "--provider", "replay",
        "--provider-trace", trace, "--teach", env:
      )
      assert_equal 0, status, out
      assert_match(/taught  /, out)
      assert_match(/status   done/, out)

      write_done_trace(trace)
      out, status = run_cli(
        "task", "--app", "Finder", "--goal", "Inspect the fixture", "--provider", "replay",
        "--provider-trace", trace, env:
      )
      assert_equal 0, status, out
      assert_match(/skill   /, out)

      blocked = File.join(env.fetch("WRANGLE_HOME"), "not-a-directory")
      File.write(blocked, "")
      write_done_trace(trace)
      out, status = run_cli(
        "task", "--app", "Finder", "--goal", "Inspect something else", "--provider", "replay",
        "--provider-trace", trace, "--teach", env: env.merge("WRANGLE_SKILLS_DIR" => blocked)
      )
      assert_equal 0, status, out
      assert_match(/teach    /, out)
    end
  end

  private

  def run_cli_input(input, *argv, env:)
    out, error, status = Open3.capture3(
      env, RbConfig.ruby, "--disable-gems", "-I", LIB, EXE, *argv, stdin_data: input
    )
    [out + error, status.exitstatus]
  end

  def write_done_trace(path)
    File.write(path, JSON.generate(
      "name" => "action",
      "answer" => {
        "choice" => "DONE", "confidence" => 0.91,
        "probabilities" => { "a1" => 0.02, "DONE" => 0.91, "BLOCKED" => 0.04, "HANDOFF" => 0.03 }
      }
    ) << "\n")
  end

  def with_fake_commands(helper_mode: "driver")
    Dir.mktmpdir("wrangle-cli") do |directory|
      macos = wrapper(directory, "macos", FAKE_MACOS, helper_mode)
      yield("WRANGLE_MACOS_HELPER" => macos, "WRANGLE_HOME" => directory)
    end
  end

  def with_fake_tart_commands
    Dir.mktmpdir("wrangle-tart-cli") do |directory|
      tart = wrapper(directory, "tart", FAKE_TART, nil)
      helper = wrapper(directory, "guest-helper", FAKE_MACOS, "driver")
      yield({ "WRANGLE_TART" => tart, "WRANGLE_HOME" => directory }, helper)
    end
  end

  def wrapper(directory, name, fixture, mode)
    path = File.join(directory, name)
    parts = [RbConfig.ruby, "--disable-gems", fixture, mode]
    command = parts.compact.map { |part| Shellwords.escape(part) }.join(" ")
    File.write(path, "#!/bin/sh\nexec #{command} \"$@\"\n")
    File.chmod(0o700, path)
    path
  end
end
