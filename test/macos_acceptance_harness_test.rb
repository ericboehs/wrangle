# frozen_string_literal: true

require_relative "test_helper"
require_relative "../script/lib/macos_acceptance"

class MacOSAcceptanceHarnessTest < Minitest::Test
  Acceptance = Wrangle::MacOSAcceptance

  class FakeDriver
    attr_accessor :doctor_result, :found_windows, :observation, :failure
    attr_reader :window_request, :attached, :closed

    def initialize
      @doctor_result = {
        "ready" => true, "session_locked" => false, "driver" => "macos_native", "displays" => 2
      }
      @found_windows = [{ "id" => "private-window-id", "app_name" => "Fixture", "focused" => true }]
      @observation = MacOSAcceptanceHarnessTest.observation
    end

    def doctor = doctor_result

    def windows(app:, titles:)
      @window_request = [app, titles]
      raise failure if failure

      found_windows
    end

    def attach(window_id:, app:)
      @attached = [window_id, app]
      Object.new
    end

    def observe(_scope) = observation
    def close = @closed = true
  end

  class FakePreparer
    attr_reader :profiles

    def initialize
      @profiles = []
    end

    def call(profile)
      @profiles << profile["id"]
      "prepared"
    end
  end

  def self.observation(complete: true, provenance: %w[ax macos_helper_native], candidates: 1,
                       ambiguous: 0)
    listed = Array.new(candidates) do |index|
      {
        "ref" => "private-ref-#{index}", "role" => "button", "label" => "PRIVATE LABEL #{index}",
        "value" => "PRIVATE VALUE", "states" => ["enabled"], "operations" => ["PRESS"]
      }
    end
    {
      "complete" => complete,
      "tree" => {
        "role" => "window", "name" => "PRIVATE WINDOW TITLE",
        "children" => [{ "role" => "statictext", "name" => "PRIVATE DOCUMENT CONTENT", "children" => [] }]
      },
      "candidates" => listed,
      "ambiguous_actions" => Array.new(ambiguous) { { "label" => "PRIVATE DUPLICATE", "matches" => 2 } },
      "coverage" => {
        "truncated" => !complete, "candidate_count" => candidates,
        "ambiguous_action_count" => ambiguous * 2, "provenance" => provenance
      },
      "observation_setup" => {
        "changed" => true, "verified" => true, "snapshot_source" => "macos_helper_native",
        "private_detail" => "PRIVATE SETUP"
      }
    }
  end

  def setup
    @tmpdir = Dir.mktmpdir("wrangle-acceptance-test")
    @matrix = Acceptance::Matrix.new(matrix_document)
    @driver = FakeDriver.new
    @preparer = FakePreparer.new
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def test_checked_in_matrix_is_valid_and_selectable
    matrix = Acceptance::Matrix.load(Acceptance::DEFAULT_MATRIX)

    assert_operator matrix.profiles.length, :>=, 12
    assert_equal(
      %w[finder system-settings slack microsoft-teams],
      matrix.select(tier: "core").map { |profile| profile["id"] }
    )
    assert_equal(["finder"], matrix.select(ids: %w[finder finder]).map { |profile| profile["id"] })
    assert_raises(Acceptance::HarnessError) { matrix.select(ids: ["missing"]) }
    assert_raises(Acceptance::HarnessError) { matrix.select(ids: ["finder"], tier: "core") }
    assert_raises(Acceptance::HarnessError) { matrix.select }
    assert_raises(Acceptance::HarnessError) { matrix.select(tier: "missing") }
  end

  def test_probe_report_is_exact_window_sanitized_and_repeatable
    runner = runner_for(@driver)
    profile = @matrix.profiles.first
    report = runner.run(mode: "probe", profiles: [profile], runs: 2, prepare: true)
    first = report.dig("profiles", 0, "runs", 0)

    assert report["passed"]
    assert_equal 1.0, report.dig("profiles", 0, "pass_rate")
    assert_equal({ "median" => 20.0, "p95" => 20.0, "min" => 20.0, "max" => 20.0 },
                 report.dig("profiles", 0, "timing_ms"))
    assert_match(/\A[0-9a-f]{64}\z/, report["matrix_sha256"])
    assert_equal ["Fixture", false], @driver.window_request
    assert_equal %w[private-window-id Fixture], @driver.attached
    assert @driver.closed
    assert_equal %w[fixture fixture], @preparer.profiles
    assert_equal "only_visible_window", first["selection"]
    assert_equal 2, first["tree_nodes"]
    assert_equal 1, first["candidate_count"]
    assert_equal 2, first["evidence_count"]
    assert_equal({ "changed" => true, "verified" => true,
                   "snapshot_source" => "macos_helper_native" }, first["observation_setup"])
    serialized = JSON.generate(report)
    refute_includes serialized, "PRIVATE"
    refute_includes serialized, "private-window-id"
    refute_includes serialized, "private-ref"
  end

  def test_probe_selects_one_focused_window_and_names_expectation_failures
    @driver.found_windows = [
      { "id" => "one", "app_name" => "Fixture", "focused" => false },
      { "id" => "two", "app_name" => "Fixture", "focused" => true }
    ]
    @driver.observation = self.class.observation(complete: false, provenance: ["ax"], candidates: 0, ambiguous: 2)
    profile = deep_copy(@matrix.profiles.first)
    profile["expect"] = {
      "complete" => true, "min_candidates" => 1, "min_evidence" => 3,
      "max_ambiguous_actions" => 1, "provenance" => %w[ax macos_helper_native]
    }

    result = runner_for(@driver).run(mode: "probe", profiles: [profile], runs: 1)
                                .dig("profiles", 0, "runs", 0)

    refute result["passed"]
    assert_equal "unique_focused_window", result["selection"]
    assert_equal %w[observation_incomplete too_few_candidates too_few_evidence_items
                    too_many_ambiguous_actions missing_provenance], result["failures"]
  end

  def test_prepared_probe_waits_for_a_cold_application_window
    calls = 0
    @driver.define_singleton_method(:windows) do |app:, titles:|
      @window_request = [app, titles]
      calls += 1
      raise Wrangle::DriverRefusal.new("app_not_found", "still launching") if calls == 1

      found_windows
    end
    profile = deep_copy(@matrix.profiles.first)
    profile["preparation"]["ready_timeout_seconds"] = 1
    profile["preparation"]["ready_poll_seconds"] = 0.01

    result = runner_for(@driver).run(mode: "probe", profiles: [profile], runs: 1, prepare: true)
                                .dig("profiles", 0, "runs", 0)

    assert result["passed"]
    assert_equal "prepared", result["preparation"]
    assert_equal 2, calls
  end

  def test_preparation_failure_is_distinct_from_a_probe_failure
    failing_preparer = Object.new
    failing_preparer.define_singleton_method(:call) { |_profile| raise "PRIVATE PREPARATION ERROR" }
    runner = runner_for(@driver, preparer: failing_preparer)

    result = runner.run(mode: "probe", profiles: @matrix.profiles, runs: 1, prepare: true)
                   .dig("profiles", 0, "runs", 0)

    assert_equal "failed", result["preparation"]
    refute_includes JSON.generate(result), "PRIVATE PREPARATION ERROR"
  end

  def test_probe_fails_closed_without_driver_readiness_or_exact_selection
    @driver.doctor_result = { "ready" => false, "session_locked" => true }
    locked = runner_for(@driver).run(mode: "probe", profiles: @matrix.profiles, runs: 1)
                                .dig("profiles", 0, "runs", 0)
    assert_equal ["driver_not_ready"], locked["failures"]
    assert locked["session_locked"]
    assert @driver.closed

    ambiguous_driver = FakeDriver.new
    ambiguous_driver.found_windows = [
      { "id" => "private-one", "app_name" => "Fixture", "focused" => false },
      { "id" => "private-two", "app_name" => "Fixture", "focused" => false }
    ]
    report = runner_for(ambiguous_driver).run(mode: "probe", profiles: @matrix.profiles, runs: 1)
    failed = report.dig("profiles", 0, "runs", 0)
    assert_equal ["exception"], failed["failures"]
    assert_equal "Wrangle::ScopeLost", failed["error_class"]
    refute_includes JSON.generate(failed), "private-one"
    assert ambiguous_driver.closed
  end

  def test_probe_exception_drops_the_message
    @driver.failure = Wrangle::ScopeLost.new("PRIVATE ERROR MESSAGE")
    result = runner_for(@driver).run(mode: "probe", profiles: @matrix.profiles, runs: 1)
                                .dig("profiles", 0, "runs", 0)

    assert_equal "Wrangle::ScopeLost", result["error_class"]
    refute_includes JSON.generate(result), "PRIVATE ERROR MESSAGE"
  end

  def test_task_report_keeps_provenance_but_drops_ui_content
    raw = {
      "status" => "done", "actions_taken" => 0, "remaining" => 1, "root_preserved" => true,
      "message" => "PRIVATE MESSAGE",
      "decision" => { "operation" => "DONE", "confidence" => 0.91, "provider" => "fixture",
                      "model" => "recorded-v1", "private" => "PRIVATE DECISION" },
      "evidence" => { "complete" => true, "total" => 3, "omitted" => 0,
                      "explicit_truncation" => false, "selection" => "bounded",
                      "items" => [{ "label" => "PRIVATE EVIDENCE" }] },
      "actions" => []
    }
    runner = runner_for(@driver, task_runner: ->(_profile, _options, _allow) { raw })
    result = runner.run(
      mode: "task", profiles: @matrix.profiles, runs: 1,
      provider_options: { "provider" => "replay" }
    ).dig("profiles", 0, "runs", 0)

    assert result["passed"]
    assert_equal "recorded-v1", result.dig("decision", "model")
    assert_equal 3, result.dig("evidence", "total")
    refute_includes JSON.generate(result), "PRIVATE"
  end

  def test_task_rejects_unexpected_or_unverified_action_results
    profile = deep_copy(@matrix.profiles.first)
    profile["task"]["max_actions"] = 2
    raw = {
      "status" => "blocked", "actions_taken" => 2, "remaining" => 0, "root_preserved" => false,
      "decision" => {}, "evidence" => {},
      "actions" => [
        { "operation" => "PRESS", "label" => "PRIVATE", "dispatch" => "delivery_unknown",
          "effect" => "unverified", "terminal" => true },
        { "operation" => "PRESS", "dispatch" => "delivered", "effect" => "unchanged", "terminal" => false }
      ]
    }
    runner = runner_for(@driver, task_runner: ->(_selected, _options, _allow) { raw })
    result = runner.run(
      mode: "task", profiles: [profile], runs: 1, allow_actions: true,
      provider_options: { "provider" => "replay", "provider_qualification" => "receipt.json" }
    ).dig("profiles", 0, "runs", 0)

    refute result["passed"]
    assert_equal %w[unexpected_status root_not_preserved uncertain_delivery effect_not_verified], result["failures"]
    refute_includes JSON.generate(result), "PRIVATE"
  end

  def test_task_mode_requires_explicit_paired_action_authorization
    runner = runner_for(@driver, task_runner: ->(*) { raise "not reached" })

    error = assert_raises(Acceptance::HarnessError) do
      runner.run(mode: "task", profiles: @matrix.profiles, runs: 1)
    end
    assert_match(/requires --provider/, error.message)

    assert_raises(Acceptance::HarnessError) do
      runner.run(mode: "task", profiles: @matrix.profiles, runs: 1,
                 provider_options: { "provider" => "jev", "provider_qualification" => "receipt" })
    end
    assert_raises(Acceptance::HarnessError) do
      runner.run(mode: "task", profiles: @matrix.profiles, runs: 1, allow_actions: true,
                 provider_options: { "provider" => "jev" })
    end
    assert_raises(Acceptance::HarnessError) do
      runner.run(mode: "task", profiles: @matrix.profiles, runs: 1, allow_actions: true,
                 provider_options: { "provider" => "jev", "provider_qualification" => "receipt" })
    end
  end

  def test_runner_validates_mode_runs_and_task_presence
    runner = runner_for(@driver)
    assert_raises(Acceptance::HarnessError) do
      runner.run(mode: "other", profiles: @matrix.profiles, runs: 1)
    end
    assert_raises(Acceptance::HarnessError) do
      runner.run(mode: "probe", profiles: @matrix.profiles, runs: 0)
    end
    profile = deep_copy(@matrix.profiles.first)
    profile.delete("task")
    assert_raises(Acceptance::HarnessError) do
      runner.run(mode: "task", profiles: [profile], runs: 1, provider_options: { "provider" => "jev" })
    end
  end

  def test_preparer_uses_argument_arrays_and_refuses_manual_setup
    commands = []
    sleeps = []
    preparer = Acceptance::Preparer.new(
      root: @tmpdir, command: lambda { |*argv|
        commands << argv
        true
      }, sleeper: ->(seconds) { sleeps << seconds }
    )
    profile = @matrix.profiles.first

    assert_equal "prepared", preparer.call(profile)
    assert_equal "/usr/bin/open", commands.first.first
    assert_equal "Wrangle", File.read(File.join(@tmpdir, "fixture", "wrangle-acceptance-marker.txt")).split.first
    assert_equal [0.25], sleeps

    manual = deep_copy(profile)
    manual["preparation"] = { "kind" => "manual" }
    assert_raises(Acceptance::HarnessError) { preparer.call(manual) }
  end

  def test_preparer_creates_textedit_and_preview_fixtures_without_shells
    commands = []
    preparer = Acceptance::Preparer.new(
      root: @tmpdir, command: lambda { |*argv|
        commands << argv
        true
      }, sleeper: ->(*) {}
    )
    textedit = deep_copy(Acceptance::Matrix.load(Acceptance::DEFAULT_MATRIX).profiles
                                   .find { |profile| profile["id"] == "textedit" })
    preview = deep_copy(Acceptance::Matrix.load(Acceptance::DEFAULT_MATRIX).profiles
                                  .find { |profile| profile["id"] == "preview" })

    assert_equal "prepared", preparer.call(textedit)
    assert_equal "prepared", preparer.call(preview)
    assert_equal "Wrangle document acceptance fixture.",
                 File.read(File.join(@tmpdir, "textedit", "wrangle-document-fixture.txt"))
    pdf = File.binread(File.join(@tmpdir, "preview", "wrangle-preview-fixture.pdf"))
    assert pdf.start_with?("%PDF-1.4\n")
    assert_includes pdf, "Wrangle Preview acceptance fixture."
    assert_includes commands, ["/usr/bin/open", "-a", "TextEdit",
                               File.join(@tmpdir, "textedit", "wrangle-document-fixture.txt")]
    assert_includes commands, ["/usr/bin/open", "-a", "Preview",
                               File.join(@tmpdir, "preview", "wrangle-preview-fixture.pdf")]
  end

  def test_environment_reports_revision_dirtiness_without_status_content
    success = Object.new
    success.define_singleton_method(:success?) { true }
    command = lambda do |*argv|
      value = argv.include?("status") ? " M PRIVATE-PATH\n" : "fixture-value\n"
      [value, "", success]
    end

    environment = Acceptance::Environment.capture(root: "/PRIVATE/ROOT", command:)

    assert environment["git_dirty"]
    assert_equal "fixture-value", environment["git_revision"]
    refute_includes JSON.generate(environment), "PRIVATE"
  end

  def test_report_writer_is_atomic_and_private
    path = File.join(@tmpdir, "reports", "result.json")
    Acceptance::ReportWriter.write(path, "passed" => true)

    assert_equal({ "passed" => true }, JSON.parse(File.read(path)))
    assert_equal 0o600, File.stat(path).mode & 0o777
    assert_empty Dir.glob(File.join(File.dirname(path), ".*.tmp"))
  end

  def test_matrix_validation_rejects_unsafe_or_incomplete_definitions
    duplicate = matrix_document
    duplicate["profiles"] << deep_copy(duplicate["profiles"].first)
    assert_raises(Acceptance::HarnessError) { Acceptance::Matrix.new(duplicate) }

    invalid = matrix_document
    invalid["profiles"].first["preparation"] = { "kind" => "shell" }
    assert_raises(Acceptance::HarnessError) { Acceptance::Matrix.new(invalid) }

    invalid = matrix_document
    invalid["profiles"].first["expect"] = { "min_candidates" => -1 }
    assert_raises(Acceptance::HarnessError) { Acceptance::Matrix.new(invalid) }

    invalid = matrix_document
    invalid["profiles"].first["task"]["steps"] = 99
    assert_raises(Acceptance::HarnessError) { Acceptance::Matrix.new(invalid) }

    invalid = matrix_document
    invalid["profiles"].first["preparation"]["ready_timeout_seconds"] = 61
    assert_raises(Acceptance::HarnessError) { Acceptance::Matrix.new(invalid) }
  end

  def test_cli_lists_profiles_without_touching_an_application
    root = File.expand_path("..", __dir__)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "--disable-gems", "script/macos_accept", "--list", chdir: root
    )

    assert status.success?, stderr
    assert_includes stdout, "microsoft-teams"
    assert_includes stdout, "boundary_only"
    assert_empty stderr
  end

  private

  def runner_for(driver, task_runner: nil, preparer: @preparer)
    tick = 0.0
    Acceptance::Runner.new(
      matrix: @matrix, driver_factory: -> { driver }, task_runner:,
      preparer:, monotonic: -> { tick += 0.01 }, sleeper: ->(_seconds) {},
      wall_clock: -> { Time.utc(2026, 9, 19, 12) }, environment: -> { { "fixture" => true } }
    )
  end

  def matrix_document
    {
      "schema" => Acceptance::MATRIX_SCHEMA, "updated" => "2026-09-19",
      "profiles" => [{
        "id" => "fixture", "app" => "Fixture", "family" => "native", "tier" => "core",
        "environment" => "test", "status" => "pending",
        "preparation" => { "kind" => "finder_fixture", "settle_seconds" => 0.25 },
        "expect" => {
          "complete" => true, "min_candidates" => 1, "min_evidence" => 1,
          "provenance" => %w[ax macos_helper_native]
        },
        "task" => {
          "goal" => "Confirm the fixture is visible.", "steps" => 1, "min_confidence" => 0.5,
          "expected_statuses" => ["done"], "max_actions" => 0
        }
      }]
    }
  end

  def deep_copy(value) = JSON.parse(JSON.generate(value))
end
