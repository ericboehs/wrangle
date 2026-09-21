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

  private

  def run_cli_input(input, *argv, env:)
    out, error, status = Open3.capture3(
      env, RbConfig.ruby, "--disable-gems", "-I", LIB, EXE, *argv, stdin_data: input
    )
    [out + error, status.exitstatus]
  end

  def with_fake_commands(helper_mode: "driver")
    Dir.mktmpdir("wrangle-cli") do |directory|
      macos = wrapper(directory, "macos", FAKE_MACOS, helper_mode)
      yield("WRANGLE_MACOS_HELPER" => macos, "WRANGLE_HOME" => directory)
    end
  end

  def wrapper(directory, name, fixture, mode)
    path = File.join(directory, name)
    command = [RbConfig.ruby, "--disable-gems", fixture, mode].map { |part| Shellwords.escape(part) }.join(" ")
    File.write(path, "#!/bin/sh\nexec #{command} \"$@\"\n")
    File.chmod(0o700, path)
    path
  end
end
