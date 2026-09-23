# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "time"
require "tmpdir"

require_relative "../../lib/wrangle"

module Wrangle
  # Local, stdlib-only acceptance tooling for the exact-window macOS driver. Reports deliberately
  # contain counts and provenance, never AX labels, values, window titles, ids, or process ids.
  module MacOSAcceptance
    REPORT_SCHEMA = "wrangle.macos-acceptance-report.v1"
    MATRIX_SCHEMA = "wrangle.macos-acceptance-matrix.v1"
    DEFAULT_MATRIX = File.expand_path("../../test/acceptance/macos_apps.json", __dir__)
    MAX_MATRIX_BYTES = 128 * 1024
    MAX_RUNS = 20

    class HarnessError < StandardError; end

    class Matrix
      PROFILE_KEYS = %w[id app family tier environment status preparation expect].freeze
      PREPARATIONS = %w[
        finder_fixture open_app preview_fixture settings_accessibility textedit_fixture manual
      ].freeze

      attr_reader :document, :profiles

      def self.load(path)
        raise HarnessError, "Acceptance matrix is too large" if File.size(path) > MAX_MATRIX_BYTES

        new(JSON.parse(File.read(path)))
      rescue SystemCallError, JSON::ParserError => e
        raise HarnessError, "Could not load acceptance matrix: #{e.class.name.split("::").last}"
      end

      def initialize(document)
        @document = document
        validate!
        @profiles = document.fetch("profiles")
        @by_id = @profiles.to_h { |profile| [profile.fetch("id"), profile] }
      end

      def select(ids: [], tier: nil)
        raise HarnessError, "Choose profile ids or --tier, not both" if tier && !ids.empty?

        if tier
          selected = profiles.select { |profile| profile.fetch("tier") == tier }
          raise HarnessError, "No profiles belong to tier #{tier.inspect}" if selected.empty?

          return selected
        end

        raise HarnessError, "At least one application profile is required" if ids.empty?

        ids.uniq.map do |id|
          @by_id.fetch(id) { raise HarnessError, "Unknown application profile #{id.inspect}" }
        end
      end

      private

      def validate!
        valid_schema = document.is_a?(Hash) && document["schema"] == MATRIX_SCHEMA
        raise HarnessError, "Unsupported acceptance matrix schema" unless valid_schema

        listed = document["profiles"]
        raise HarnessError, "Acceptance matrix needs profiles" unless listed.is_a?(Array) && !listed.empty?

        listed.each { |profile| validate_profile!(profile) }
        ids = listed.map { |profile| profile["id"] }
        raise HarnessError, "Acceptance profile ids must be unique" unless ids.uniq.length == ids.length
      end

      def validate_profile!(profile)
        unless profile.is_a?(Hash) && PROFILE_KEYS.all? { |key| profile.key?(key) }
          raise HarnessError, "Acceptance profile is incomplete"
        end

        valid_id = profile["id"].is_a?(String) && profile["id"].match?(/\A[a-z0-9-]+\z/)
        raise HarnessError, "Invalid acceptance profile id" unless valid_id

        %w[app family tier environment status].each do |key|
          raise HarnessError, "Invalid #{key} for #{profile["id"]}" unless nonempty_string?(profile[key])
        end
        validate_preparation!(profile)
        validate_expectations!(profile)
        validate_task!(profile) if profile.key?("task")
      end

      def validate_preparation!(profile)
        preparation = profile["preparation"]
        unless preparation.is_a?(Hash) && PREPARATIONS.include?(preparation["kind"])
          raise HarnessError, "Invalid preparation for #{profile["id"]}"
        end

        settle = preparation.fetch("settle_seconds", 0)
        ready_timeout = preparation.fetch("ready_timeout_seconds", 0)
        ready_poll = preparation.fetch("ready_poll_seconds", 1)
        valid = settle.is_a?(Numeric) && settle.between?(0, 10) &&
                ready_timeout.is_a?(Numeric) && ready_timeout.between?(0, 60) &&
                ready_poll.is_a?(Numeric) && ready_poll.positive? && ready_poll <= 5
        raise HarnessError, "Invalid preparation timing for #{profile["id"]}" unless valid
      end

      def validate_expectations!(profile)
        expect = profile["expect"]
        raise HarnessError, "Invalid expectations for #{profile["id"]}" unless expect.is_a?(Hash)

        %w[min_candidates min_evidence max_ambiguous_actions].each do |key|
          next unless expect.key?(key)
          next if expect[key].is_a?(Integer) && expect[key] >= 0

          raise HarnessError, "Invalid #{key} for #{profile["id"]}"
        end
        provenance = expect["provenance"]
        invalid_provenance = expect.key?("provenance") &&
                             (!provenance.is_a?(Array) || !provenance.all? { |item| nonempty_string?(item) })
        raise HarnessError, "Invalid provenance for #{profile["id"]}" if invalid_provenance
      end

      def validate_task!(profile)
        task = profile["task"]
        unless task.is_a?(Hash) && nonempty_string?(task["goal"]) &&
               task["expected_statuses"].is_a?(Array) && !task["expected_statuses"].empty? &&
               task["expected_statuses"].all? { |status| nonempty_string?(status) } &&
               task["steps"].is_a?(Integer) && task["steps"].between?(1, DesktopTask::MAX_STEPS) &&
               task["max_actions"].is_a?(Integer) && task["max_actions"].between?(0, DesktopTask::MAX_STEPS)
          raise HarnessError, "Invalid task for #{profile["id"]}"
        end
      end

      def nonempty_string?(value) = value.is_a?(String) && !value.strip.empty?
    end

    class Preparer
      def initialize(root: File.join(Dir.tmpdir, "wrangle-macos-acceptance"), command: nil, sleeper: nil)
        @root = root
        @command = command || ->(*argv) { system(*argv, out: File::NULL, err: File::NULL) }
        @sleeper = sleeper || Kernel.method(:sleep)
      end

      def call(profile)
        preparation = profile.fetch("preparation")
        case preparation.fetch("kind")
        when "finder_fixture" then prepare_finder(profile)
        when "settings_accessibility" then open_settings
        when "textedit_fixture" then prepare_textedit(profile)
        when "preview_fixture" then prepare_preview(profile)
        when "open_app" then command!("/usr/bin/open", "-a", profile.fetch("app"))
        when "manual" then raise HarnessError, "#{profile.fetch("id")} requires manual preparation"
        end
        settle = preparation.fetch("settle_seconds", 0).to_f
        @sleeper.call(settle) if settle.positive?
        "prepared"
      end

      private

      def fixture_directory(profile)
        path = File.join(@root, profile.fetch("id"))
        FileUtils.mkdir_p(path, mode: 0o700)
        path
      end

      def prepare_finder(profile)
        path = fixture_directory(profile)
        marker = File.join(path, "wrangle-acceptance-marker.txt")
        File.write(marker, "Wrangle disposable Finder acceptance marker.\n", mode: "w", perm: 0o600)
        command!("/usr/bin/open", path)
      end

      def prepare_textedit(profile)
        path = File.join(fixture_directory(profile), "wrangle-document-fixture.txt")
        File.write(path, "Wrangle document acceptance fixture.", mode: "w", perm: 0o600)
        command!("/usr/bin/open", "-a", profile.fetch("app"), path)
      end

      def prepare_preview(profile)
        path = File.join(fixture_directory(profile), "wrangle-preview-fixture.pdf")
        File.binwrite(path, preview_pdf, mode: "w", perm: 0o600)
        command!("/usr/bin/open", "-a", profile.fetch("app"), path)
      end

      def preview_pdf
        objects = [
          "<< /Type /Catalog /Pages 2 0 R >>",
          "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
          "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
          "/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
          "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ]
        content = "BT /F1 18 Tf 72 720 Td (Wrangle Preview acceptance fixture.) Tj ET"
        objects << "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream"
        pdf = +"%PDF-1.4\n"
        offsets = objects.each_with_index.map do |object, index|
          pdf.bytesize.tap { pdf << "#{index + 1} 0 obj\n#{object}\nendobj\n" }
        end
        xref = pdf.bytesize
        pdf << "xref\n0 #{objects.length + 1}\n0000000000 65535 f \n"
        offsets.each { |offset| pdf << format("%010d 00000 n \n", offset) }
        pdf << "trailer\n<< /Size #{objects.length + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
      end

      def open_settings
        command!("/usr/bin/open", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
      end

      def command!(*argv)
        raise HarnessError, "Application preparation failed" unless @command.call(*argv)
      end
    end

    class Environment
      def self.capture(root: File.expand_path("../..", __dir__), command: Open3.method(:capture3))
        {
          "os_version" => value(command, "/usr/bin/sw_vers", "-productVersion"),
          "os_build" => value(command, "/usr/bin/sw_vers", "-buildVersion"),
          "architecture" => RbConfig::CONFIG.fetch("host_cpu"),
          "wrangle_version" => Wrangle::VERSION,
          "git_revision" => value(command, "/usr/bin/git", "-C", root, "rev-parse", "HEAD"),
          "git_dirty" => dirty?(command, root)
        }
      end

      def self.value(command, *argv)
        stdout, _stderr, status = command.call(*argv)
        status.success? ? stdout.strip : "unknown"
      rescue Errno::ENOENT
        "unknown"
      end
      private_class_method :value

      def self.dirty?(command, root)
        stdout, _stderr, status = command.call("/usr/bin/git", "-C", root, "status", "--porcelain")
        status.success? ? !stdout.empty? : nil
      rescue Errno::ENOENT
        nil
      end
      private_class_method :dirty?
    end

    class Runner
      def initialize(matrix:, driver_factory: nil, task_runner: nil, preparer: nil, monotonic: nil,
                     sleeper: nil, wall_clock: nil, environment: nil, progress: nil)
        @matrix = matrix
        @driver_factory = driver_factory || -> { MacOSDriver.new }
        @task_runner = task_runner || method(:run_desktop_task)
        @preparer = preparer || Preparer.new
        @monotonic = monotonic || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @sleeper = sleeper || Kernel.method(:sleep)
        @wall_clock = wall_clock || -> { Time.now.utc }
        @environment = environment || -> { Environment.capture }
        @progress = progress
      end

      def run(mode:, profiles:, runs:, prepare: false, provider_options: {}, allow_actions: false)
        validate_run!(mode, profiles, runs, provider_options, allow_actions)
        results = profiles.map do |profile|
          profile_result(profile, mode, runs, prepare, provider_options, allow_actions)
        end
        report(mode, runs, prepare, results)
      end

      private

      def validate_run!(mode, profiles, runs, provider_options, allow_actions)
        raise HarnessError, "Mode must be probe or task" unless %w[probe task].include?(mode)

        valid_runs = runs.is_a?(Integer) && runs.between?(1, MAX_RUNS)
        raise HarnessError, "Runs must be between 1 and #{MAX_RUNS}" unless valid_runs
        return unless mode == "task"

        raise HarnessError, "Task mode requires --provider" if provider_options["provider"].to_s.empty?

        profiles.each do |profile|
          raise HarnessError, "#{profile.fetch("id")} has no task scenario" unless profile["task"]
        end
        qualified = !provider_options["provider_qualification"].to_s.empty?
        raise HarnessError, "--provider-qualification requires --allow-actions" if qualified && !allow_actions
        raise HarnessError, "--allow-actions requires --provider-qualification" if allow_actions && !qualified
        return unless allow_actions && profiles.any? { |profile| profile.dig("task", "max_actions").zero? }

        raise HarnessError, "Selected profiles prohibit delivered actions"
      end

      def profile_result(profile, mode, runs, prepare, provider_options, allow_actions)
        attempts = Array.new(runs) do |index|
          result = attempt(profile, mode, prepare, provider_options, allow_actions)
          @progress&.call(profile, index + 1, runs, result)
          result
        end
        passed = attempts.count { |attempt| attempt["passed"] }
        {
          "id" => profile.fetch("id"), "app" => profile.fetch("app"),
          "family" => profile.fetch("family"), "tier" => profile.fetch("tier"),
          "environment" => profile.fetch("environment"), "declared_status" => profile.fetch("status"),
          "passed" => passed == attempts.length, "pass_rate" => passed.to_f / attempts.length,
          "timing_ms" => timing_summary(attempts), "runs" => attempts
        }
      end

      def timing_summary(attempts)
        timings = attempts.map { |attempt| attempt.fetch("elapsed_ms") }.sort
        {
          "median" => timings[(timings.length * 0.5).floor],
          "p95" => timings[[(timings.length * 0.95).ceil - 1, 0].max],
          "min" => timings.first, "max" => timings.last
        }
      end

      def attempt(profile, mode, prepare, provider_options, allow_actions)
        started = @monotonic.call
        preparation = prepare ? "attempted" : "not_requested"
        preparation = @preparer.call(profile) if prepare
        result = if mode == "probe"
                   probe(profile, wait_for_window: prepare)
                 else
                   task(profile, provider_options, allow_actions)
                 end
        result.merge("preparation" => preparation,
                     "elapsed_ms" => ((@monotonic.call - started) * 1000).round(1))
      rescue StandardError => e
        {
          "passed" => false,
          "preparation" => preparation == "attempted" ? "failed" : preparation,
          "elapsed_ms" => ((@monotonic.call - started) * 1000).round(1),
          "failures" => ["exception"], "error_class" => e.class.name
        }
      end

      def probe(profile, wait_for_window:)
        driver = @driver_factory.call
        doctor = driver.doctor
        base = safe_doctor(doctor)
        return base.merge("passed" => false, "failures" => ["driver_not_ready"]) unless doctor["ready"] == true

        windows = windows_for(driver, profile, wait_for_window)
        window, selection = select_window(windows, profile.fetch("app"))
        scope = driver.attach(window_id: window.fetch("id"), app: window.fetch("app_name"))
        observation = driver.observe(scope)
        summarize_probe(base, observation, windows.length, selection, profile.fetch("expect"))
      ensure
        driver&.close
      end

      def windows_for(driver, profile, wait_for_window)
        preparation = profile.fetch("preparation")
        timeout = wait_for_window ? preparation.fetch("ready_timeout_seconds", 0).to_f : 0
        deadline = @monotonic.call + timeout
        loop do
          windows = begin
            driver.windows(app: profile.fetch("app"), titles: false)
          rescue DriverRefusal => e
            raise unless e.code == "app_not_found" && @monotonic.call < deadline

            []
          end
          return windows unless windows.empty? && @monotonic.call < deadline

          @sleeper.call(preparation.fetch("ready_poll_seconds", 1).to_f)
        end
      end

      def select_window(windows, app)
        raise ScopeLost, "No visible #{app} window is available" if windows.empty?
        return [windows.first, "only_visible_window"] if windows.one?

        focused = windows.select { |window| window["focused"] == true }
        return [focused.first, "unique_focused_window"] if focused.one?

        raise ScopeLost, "More than one #{app} window is visible and none is uniquely focused"
      end

      def safe_doctor(doctor)
        {
          "ready" => doctor["ready"] == true, "session_locked" => doctor["session_locked"] == true,
          "driver" => doctor["driver"].to_s[0, 64], "displays" => doctor["displays"].to_i
        }
      end

      def summarize_probe(base, observation, window_count, selection, expectations)
        coverage = observation.fetch("coverage", {})
        candidates = Array(observation["candidates"])
        evidence_count = DesktopObservation.evidence_items(observation).length
        result = base.merge(
          "window_count" => window_count, "selection" => selection, "exact_window_selected" => true,
          "complete" => observation["complete"] == true, "truncated" => coverage["truncated"] == true,
          "tree_nodes" => tree_nodes(observation["tree"]), "candidate_count" => candidates.length,
          "evidence_count" => evidence_count,
          "ambiguous_action_count" => coverage.fetch("ambiguous_action_count", 0).to_i,
          "ambiguous_groups" => Array(observation["ambiguous_actions"]).length,
          "provenance" => Array(coverage["provenance"]).map { |item| item.to_s[0, 64] },
          "observation_setup" => safe_setup(observation["observation_setup"])
        )
        failures = probe_failures(result, expectations)
        result.merge("passed" => failures.empty?, "failures" => failures)
      end

      def safe_setup(setup)
        return {} unless setup.is_a?(Hash)

        setup.slice("changed", "verified", "cached", "snapshot_source")
      end

      def tree_nodes(tree)
        count = 0
        stack = tree.is_a?(Hash) ? [tree] : []
        until stack.empty?
          node = stack.pop
          count += 1
          stack.concat(Array(node["children"]).select { |child| child.is_a?(Hash) })
        end
        count
      end

      def probe_failures(result, expectations)
        failures = []
        failures << "observation_incomplete" if expectations["complete"] == true && !result["complete"]
        failures << "too_few_candidates" if result["candidate_count"] < expectations.fetch("min_candidates", 0)
        failures << "too_few_evidence_items" if result["evidence_count"] < expectations.fetch("min_evidence", 0)
        if expectations.key?("max_ambiguous_actions") &&
           result["ambiguous_action_count"] > expectations["max_ambiguous_actions"]
          failures << "too_many_ambiguous_actions"
        end
        required = Array(expectations["provenance"])
        failures << "missing_provenance" unless (required - result["provenance"]).empty?
        failures
      end

      def task(profile, provider_options, allow_actions)
        raw = @task_runner.call(profile, provider_options, allow_actions)
        task_profile = profile.fetch("task")
        actions = Array(raw["actions"])
        result = {
          "status" => raw["status"].to_s, "actions_taken" => raw["actions_taken"].to_i,
          "remaining" => raw["remaining"].to_i, "root_preserved" => raw["root_preserved"] == true,
          "decision" => safe_decision(raw["decision"]), "evidence" => safe_evidence(raw["evidence"]),
          "action_results" => actions.map { |action| safe_action(action) }
        }
        failures = task_failures(result, task_profile)
        result.merge("passed" => failures.empty?, "failures" => failures)
      end

      def safe_decision(decision)
        return {} unless decision.is_a?(Hash)

        decision.slice("operation", "confidence", "provider", "model").transform_values do |value|
          value.is_a?(String) ? value[0, 128] : value
        end
      end

      def safe_evidence(evidence)
        return {} unless evidence.is_a?(Hash)

        evidence.slice("complete", "total", "omitted", "explicit_truncation", "selection")
      end

      def safe_action(action)
        action.slice("operation", "dispatch", "effect", "terminal").transform_values do |value|
          value.is_a?(String) ? value[0, 64] : value
        end
      end

      def task_failures(result, task_profile)
        failures = []
        failures << "unexpected_status" unless task_profile.fetch("expected_statuses").include?(result["status"])
        failures << "action_limit_exceeded" if result["actions_taken"] > task_profile.fetch("max_actions")
        failures << "action_count_inconsistent" unless result["actions_taken"] == result["action_results"].length
        failures << "root_not_preserved" unless result["root_preserved"]
        failures << "uncertain_delivery" if result["action_results"].any? do |action|
          action["dispatch"] == "delivery_unknown"
        end
        unverified = result["action_results"].any? do |action|
          action["dispatch"] == "delivered" && action["effect"] != "verified"
        end
        failures << "effect_not_verified" if unverified
        failures
      end

      def run_desktop_task(profile, provider_options, _allow_actions)
        provider = ProviderFactory.build(provider_options)
        task = profile.fetch("task")
        DesktopTask.new(provider:).run(
          app: profile.fetch("app"), goal: task.fetch("goal"), literals: task.fetch("literals", {}),
          steps: task.fetch("steps"), min_confidence: task.fetch("min_confidence", 0.5),
          concurrency: "exclusive"
        )
      end

      def report(mode, runs, prepare, results)
        run_results = results.flat_map { |profile| profile.fetch("runs") }
        passed_runs = run_results.count { |result| result["passed"] }
        {
          "schema" => REPORT_SCHEMA, "at" => @wall_clock.call.iso8601,
          "matrix_updated" => @matrix.document.fetch("updated"),
          "matrix_sha256" => Digest::SHA256.hexdigest(JSON.generate(@matrix.document)), "mode" => mode,
          "runs_per_profile" => runs, "prepare" => prepare, "environment" => @environment.call,
          "summary" => {
            "profiles" => results.length, "passed_profiles" => results.count { |profile| profile["passed"] },
            "runs" => run_results.length, "passed_runs" => passed_runs,
            "failed_runs" => run_results.length - passed_runs
          },
          "passed" => results.all? { |profile| profile["passed"] }, "profiles" => results
        }
      end
    end

    class ReportWriter
      def self.write(path, report)
        target = File.expand_path(path)
        FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
        temporary = File.join(File.dirname(target), ".#{File.basename(target)}.#{Process.pid}.tmp")
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(JSON.pretty_generate(report))
          file.write("\n")
          file.flush
          file.fsync
        end
        File.rename(temporary, target)
      ensure
        FileUtils.rm_f(temporary) if defined?(temporary)
      end
    end

    class CLI
      TABLE_FORMAT = "%<id>-22s %<app>-22s %<family>-12s %<tier>-12s %<status>-23s %<environment>s"
      PROGRESS_FORMAT = "%<id>-22s %<run>d/%<total>d %<state>-4s %<detail>s %<elapsed>.1fms"

      def self.run(argv, matrix_mode: false, out: $stdout, err: $stderr)
        options = parse(argv, out)
        return 0 if options == :help

        matrix = Matrix.load(options.fetch(:matrix))
        return list(matrix, out) if options[:list]

        profiles = select_profiles(matrix, argv, options, matrix_mode)
        report = execute(matrix, profiles, options, err)
        emit(report, options, out, err)
        report["passed"] ? 0 : 1
      rescue HarnessError, OptionParser::ParseError => e
        err.puts "macOS acceptance: #{e.message}"
        2
      rescue Interrupt
        err.puts "macOS acceptance: interrupted"
        130
      end

      # OptionParser necessarily assigns every supported option into one shared result hash.
      # rubocop:disable Metrics/AbcSize
      def self.parse(argv, out)
        options = { matrix: DEFAULT_MATRIX, runs: 1, prepare: false, task: false, allow_actions: false,
                    list: false, quiet: false }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: macos_accept PROFILE... [options]"
          opts.on("--tier NAME", "select every profile in a matrix tier") { |value| options[:tier] = value }
          opts.on("--runs N", Integer, "repeat each profile (1-#{MAX_RUNS})") { |value| options[:runs] = value }
          opts.on("--prepare", "perform the profile's safe preparation") { options[:prepare] = true }
          opts.on("--task", "run the profile's bounded natural-language task") { options[:task] = true }
          opts.on("--provider NAME") { |value| options[:provider] = value }
          opts.on("--provider-model NAME") { |value| options[:provider_model] = value }
          opts.on("--provider-endpoint URL") { |value| options[:provider_endpoint] = value }
          opts.on("--provider-trace PATH") { |value| options[:provider_trace] = value }
          opts.on("--provider-qualification PATH") { |value| options[:provider_qualification] = value }
          opts.on("--provider-max-choices N", Integer) { |value| options[:provider_max_choices] = value }
          opts.on("--allow-actions", "permit qualified action profiles") { options[:allow_actions] = true }
          opts.on("--matrix PATH", "use another matrix definition") { |value| options[:matrix] = value }
          opts.on("--output PATH", "write a private JSON report") { |value| options[:output] = value }
          opts.on("--list", "list profiles without touching applications") { options[:list] = true }
          opts.on("--quiet", "suppress progress on stderr") { options[:quiet] = true }
          opts.on("-h", "--help") do
            out.puts opts
            return :help
          end
        end
        parser.parse!(argv)
        options
      end
      # rubocop:enable Metrics/AbcSize
      private_class_method :parse

      def self.list(matrix, out)
        print_profiles(matrix.profiles, out)
        0
      end
      private_class_method :list

      def self.select_profiles(matrix, ids, options, matrix_mode)
        raise HarnessError, "macos_matrix does not accept profile ids" if matrix_mode && !ids.empty?
        raise HarnessError, "macos_matrix requires --tier" if matrix_mode && options[:tier].nil?

        matrix.select(ids: matrix_mode ? [] : ids, tier: options[:tier])
      end
      private_class_method :select_profiles

      def self.execute(matrix, profiles, options, err)
        mode = options[:task] ? "task" : "probe"
        progress = progress_printer(err, mode) unless options[:quiet]
        Runner.new(matrix:, progress:).run(
          mode:, profiles:, runs: options[:runs], prepare: options[:prepare],
          provider_options: provider_options(options), allow_actions: options[:allow_actions]
        )
      end
      private_class_method :execute

      def self.emit(report, options, out, err)
        unless options[:output]
          out.puts JSON.pretty_generate(report)
          return
        end

        ReportWriter.write(options[:output], report)
        err.puts "report #{File.expand_path(options[:output])}" unless options[:quiet]
      end
      private_class_method :emit

      def self.provider_options(options)
        %i[provider provider_model provider_endpoint provider_trace provider_qualification provider_max_choices]
          .to_h { |key| [key.to_s, options[key]] }.compact
      end
      private_class_method :provider_options

      def self.print_profiles(profiles, out)
        out.puts format(
          TABLE_FORMAT, id: "PROFILE", app: "APP", family: "FAMILY", tier: "TIER", status: "STATUS",
                        environment: "ENVIRONMENT"
        )
        profiles.each do |profile|
          out.puts format(
            TABLE_FORMAT, id: profile.fetch("id"), app: profile.fetch("app"), family: profile.fetch("family"),
                          tier: profile.fetch("tier"), status: profile.fetch("status"),
                          environment: profile.fetch("environment")
          )
        end
      end
      private_class_method :print_profiles

      def self.progress_printer(err, mode)
        lambda do |profile, run, total, result|
          state = result["passed"] ? "PASS" : "FAIL"
          detail = if mode == "task"
                     "status=#{result["status"] || "error"}"
                   else
                     "candidates=#{result["candidate_count"] || 0}"
                   end
          err.puts format(
            PROGRESS_FORMAT, id: profile.fetch("id"), run:, total:, state:, detail:,
                             elapsed: result.fetch("elapsed_ms", 0.0)
          )
        end
      end
      private_class_method :progress_printer
    end
  end
end
