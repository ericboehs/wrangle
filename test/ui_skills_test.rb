# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/scripted_jev"

# Stored procedures are hints, not authority. These tests pin the fail-closed rules: a skill is only
# applied when the index can name it, a weak or invented choice explores, and teaching never copies
# the page that happened to be open.
class UiSkillsTest < Minitest::Test
  parallelize_me!

  def setup
    super
    @dir = Dir.mktmpdir("wrangle-skills")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
    super
  end

  def test_a_skill_is_a_plan_bound_to_the_live_goal_and_not_a_scrape
    skill = build_skill(stop: "Results are visible.")
    plan = skill.plan_for("Find stays")

    assert_equal 1, plan.length
    assert_includes plan.first, "Open the stays search."
    assert_includes plan.first, "Overall goal: Find stays"
    assert_includes plan.first, Wrangle::UiSkill::LIVE_REMINDER
    assert_includes plan.first, "Stop only when: Results are visible."
    bare = build_skill(stop: nil)
    refute_includes bare.plan_for("Find stays").first, "Stop only when:"
  end

  def test_matching_is_case_insensitive_for_apps_and_one_way_for_hosts
    skill = build_skill(apps: ["Safari"], hosts: ["opentable.com"])

    assert skill.surface_match?(app: "safari", host: "www.opentable.com")
    assert skill.surface_match?(app: "Safari", host: "book.opentable.com")
    refute skill.surface_match?(app: "Safari", host: "opentable.com.evil.com")
    refute skill.surface_match?(app: "Safari", host: "notable.com")
    refute skill.surface_match?(app: "Finder", host: "opentable.com")
    refute skill.surface_match?(app: "Safari", host: nil)
    refute Wrangle::UiSkill.host_match?("book.opentable.com", "opentable.com")
    refute Wrangle::UiSkill.host_match?("table.com", "notable.com")
    refute Wrangle::UiSkill.host_match?("", "opentable.com")
  end

  def test_a_browser_skill_without_a_host_or_goal_overlap_is_weak
    browser = build_skill(apps: ["Google Chrome"], hosts: [], goal_terms: [], title: "Find a table")
    desktop = build_skill(apps: ["Finder"], hosts: [], goal_terms: [])

    assert browser.weak_for?("Press the button")
    refute browser.weak_for?("Find a table for two")
    refute desktop.weak_for?("Press the button")
    refute Wrangle::UiSkill.browser_app?("Finder")
    assert Wrangle::UiSkill.browser_app?("Safari")
  end

  def test_fingerprints_ignore_order_and_ids_stay_inside_the_store_token
    left = Wrangle::UiSkill.fingerprint("Find a table for two")
    right = Wrangle::UiSkill.fingerprint("two table Find for a")

    assert_equal left, right
    refute_equal left, Wrangle::UiSkill.fingerprint("Find a hotel")
    assert_match(/\Afixture-test-#{left}\z/, Wrangle::UiSkill.derive_id(app: "Finder", host: "www.fixture.test",
                                                                        goal: "Find a table for two"))
    assert_match(/\Aapp-[0-9a-f]{12}\z/, Wrangle::UiSkill.derive_id(app: "!!!", host: nil, goal: "Find stays"))
    long = Wrangle::UiSkill.derive_id(app: "Safari", host: "#{"sub." * 40}example.com", goal: "Find stays")
    assert_match(Wrangle::UiSkill::ID, long)
    assert_operator long.length, :<=, 64
    assert_nil Wrangle::UiSkill.host_of(nil)
    assert_nil Wrangle::UiSkill.host_of("")
    assert_equal "fixture.test", Wrangle::UiSkill.host_of("https://fixture.test/stays")
    assert_nil Wrangle::UiSkill.host_of("http://[")
  end

  def test_the_schema_rejects_a_scrape_a_secret_and_a_bad_identity
    assert_kind_of Wrangle::UiSkill, Wrangle::UiSkill.from_h(document)
    reject_documents(identity_rejections)
  end

  def test_the_schema_rejects_a_bad_match_and_normalizes_a_valid_host
    reject_documents(match_rejections)
    loaded = Wrangle::UiSkill.from_h(normalized_document)
    assert_equal ["example.com"], loaded.hosts
    assert_equal ["open"], loaded.goal_terms
    assert_nil loaded.stop
    assert_equal "manual", loaded.source
  end

  def test_the_store_keeps_valid_skills_and_skips_everything_else
    store = Wrangle::SkillStore.new(dir: @dir)
    saved = store.save(build_skill)
    assert_equal 0o600, File.stat(saved).mode & 0o777
    assert_equal 0o700, File.stat(@dir).mode & 0o777
    File.write(File.join(@dir, "broken.json"), "{")
    File.write(File.join(@dir, "labeled.json"), JSON.generate(document("id" => "other-id")))
    File.write(File.join(@dir, "huge.json"), "x" * (Wrangle::SkillStore::MAX_BYTES + 1))
    File.write(File.join(@dir, "selectors.json"), JSON.generate(document("id" => "selectors", "selectors" => [1])))
    outside = File.join(Dir.mktmpdir, "outside.json")
    File.write(outside, "{}")
    File.symlink(outside, File.join(@dir, "linked.json"))

    loaded = store.load

    assert_equal ["finder-open"], loaded.map(&:id)
    assert_equal build_skill.legs, store.find("finder-open").legs
    assert_nil store.find("../etc")
    assert_nil store.find("missing")
    reasons = store.skipped.map { |item| item["reason"] }
    assert_includes reasons, "invalid json"
    assert_includes reasons, "id mismatch"
    assert_includes reasons, "too large"
    assert_includes reasons, "symlink"
    assert(reasons.any? { |reason| reason.include?("Unknown skill fields") })
    refute_includes File.read(saved), "Forma"
  end

  def test_the_store_reads_at_most_two_hundred_files_and_honors_an_explicit_directory
    201.times do |index|
      id = format("cap-%03d", index)
      File.write(File.join(@dir, "#{id}.json"), JSON.generate(document("id" => id)))
    end
    loaded = Wrangle::SkillStore.new(dir: @dir).load.map(&:id)

    assert_equal 200, loaded.length
    refute_includes loaded, "cap-200"
    assert_equal "/tmp/skills",
                 Wrangle::SkillStore.dir_from({ "WRANGLE_SKILLS_DIR" => "/tmp/skills" }, "/Users/example")
    assert_equal "/Users/example/.config/wrangle/skills", Wrangle::SkillStore.dir_from({}, "/Users/example")
    assert_equal ENV.fetch("WRANGLE_SKILLS_DIR"), Wrangle::SkillStore.default.dir
  end

  def test_zero_or_one_clear_match_does_not_ask_and_a_weak_match_explores
    store = Wrangle::SkillStore.new(dir: @dir)
    asker = ->(*) { raise "the model was asked" }
    chooser = Wrangle::SkillChooser.new(store:, asker:)

    assert_equal "none", chooser.choose(app: "Finder", host: nil, goal: "Open Search").source
    store.save(build_skill(goal_terms: ["reservation"]))
    weak = chooser.choose(app: "Finder", host: nil, goal: "Open Search")
    assert_equal "weak", weak.source
    assert_equal ["finder-open"], weak.candidate_ids
    refute weak.applied?

    store.save(build_skill(goal_terms: []))
    clear = chooser.choose(app: "finder", host: nil, goal: "Something else")
    assert_equal "clear", clear.source
    assert_equal "finder-open", clear.skill.id
    assert_in_delta 1.0, clear.confidence
  end

  def test_an_exact_fingerprint_wins_and_only_indexed_ids_are_offered
    store = Wrangle::SkillStore.new(dir: @dir)
    goal = "Open the search window"
    exact = build_skill(id: "finder-exact", fingerprint: Wrangle::UiSkill.fingerprint(goal),
                        goal_terms: %w[open search])
    other = build_skill(id: "finder-other", goal_terms: %w[open search])
    store.save(exact)
    store.save(other)
    asked = false
    resolution = Wrangle::SkillChooser.new(store:, asker: ->(*) { asked = true }).choose(app: "Finder", host: nil,
                                                                                         goal:)

    assert_equal "finder-exact", resolution.skill.id
    refute asked

    8.times { |index| store.save(build_skill(id: "finder-#{index}", goal_terms: %w[open window])) }
    seen = {}
    asker = lambda do |state, criteria, instructions|
      seen.replace(state:, criteria:, instructions:)
      skill_answer("finder-0", criteria.keys)
    end
    chosen = Wrangle::SkillChooser.new(store:, asker:).choose(app: "Finder", host: nil, goal: "Open a window")

    assert_equal "choice", chosen.source
    assert_equal "finder-0", chosen.skill.id
    assert_equal %w[goal app host], seen[:state].keys
    assert_includes seen[:criteria].keys, "none"
    refute_includes seen[:criteria].keys, "finder-7"
    assert_operator seen[:criteria].length, :<=, 8
    refute_includes seen[:instructions], "Forma"
  end

  def test_a_model_cannot_invent_a_skill_and_a_weak_or_broken_answer_explores
    store = Wrangle::SkillStore.new(dir: @dir)
    store.save(build_skill(id: "finder-a", goal_terms: %w[open search]))
    store.save(build_skill(id: "finder-b", goal_terms: %w[open window]))
    keys = %w[finder-a finder-b none]

    assert_equal "declined", choose_with(store, skill_answer("none", keys)).source
    assert_equal "rejected", choose_with(store, skill_answer("invented", keys)).source
    assert_equal "weak_choice", choose_with(store, skill_answer("finder-a", keys, confidence: 0.4, mass: 0.8)).source
    assert_equal "rejected", choose_with(store, "nope").source
    assert_equal "rejected", choose_with(store, { "choice" => "finder-a", "confidence" => 0.8 }).source
    missed = Wrangle::SkillChooser.new(store:, asker: nil)
    resolution = missed.choose(app: "Finder", host: nil, goal: "Open the search window")
    assert_equal "unavailable", resolution.source
    unavailable = Wrangle::SkillChooser.new(store:, asker: ->(*) { raise Wrangle::ProviderError, "down" })
    assert_equal "unavailable", unavailable.choose(app: "Finder", host: nil, goal: "Open the search window").source
    partial = { "finder-a" => 0.8, "finder-b" => 0.2 }
    over = { "finder-a" => 0.8, "finder-b" => 0.1, "none" => 0.1 }
    short = { "finder-a" => 0.2, "finder-b" => 0.1, "none" => 0.1 }
    assert_equal "rejected", choose_with(store, distribution(partial)).source
    assert_equal "rejected", choose_with(store, distribution(over, confidence: 1.5)).source
    assert_equal "rejected", choose_with(store, distribution(short, confidence: 0.2)).source
  end

  def test_a_provider_choice_uses_the_same_closed_set
    store = Wrangle::SkillStore.new(dir: @dir)
    store.save(build_skill(id: "finder-a", goal_terms: %w[open search]))
    store.save(build_skill(id: "finder-b", goal_terms: %w[open window]))
    seen = {}
    asker = Object.new
    asker.define_singleton_method(:choose) do |state:, name:, criteria:, instructions:|
      seen.replace(name:, state:, criteria:, instructions:)
      keys = criteria.keys
      Wrangle::DecisionProvider::Decision.new(
        choice: "finder-b", confidence: 0.82, latency_ms: 1,
        probabilities: keys.to_h { |key| [key, key == "finder-b" ? 0.82 : (0.18 / (keys.length - 1))] }
      )
    end

    resolution = Wrangle::SkillChooser.new(store:, asker:).choose(app: "Finder", host: nil, goal: "Open the window")

    assert_equal "skill", seen[:name]
    assert_equal "finder-b", resolution.skill.id
    assert_in_delta 0.82, resolution.confidence
    refute seen[:state].key?("text")
  end

  def test_jev_skill_answers_are_read_only_from_the_skill_question
    jev = Object.new
    jev.define_singleton_method(:ask) do |state:, **|
      { "answers" => { "skill" => { "choice" => state["goal"] } } }
    end
    answer = Wrangle::SkillChooser.ask_jev(jev, { "goal" => "Find stays" }, { "none" => "Explore" }, "rules")

    assert_equal "Find stays", answer["choice"]
    blank = Object.new
    blank.define_singleton_method(:ask) { |**| "nope" }
    assert_nil Wrangle::SkillChooser.ask_jev(blank, {}, {}, "rules")
    missing = Object.new
    missing.define_singleton_method(:ask) { |**| { "answers" => {} } }
    assert_nil Wrangle::SkillChooser.ask_jev(missing, {}, {}, "rules")
  end

  def test_teaching_saves_the_procedure_and_not_the_page
    store = Wrangle::SkillStore.new(dir: @dir)
    teacher = Wrangle::SkillTeacher.new(store)
    first = teacher.teach(app: "Safari", host: "www.fixture.test", goal: "Find stays",
                          legs: ["Search. Overall goal: Find stays. Stop only when: done", "x" * 300] +
                            (1..6).map { |number| "Leg #{number}" })
    loaded = store.find(first["id"])

    assert_equal 1, first["version"]
    assert_equal ["fixture.test"], loaded.hosts
    assert_equal ["Search."], [loaded.legs.first]
    assert_equal Wrangle::UiSkill::MAX_LEGS, loaded.legs.length
    assert_equal Wrangle::UiSkill::MAX_LEG, loaded.legs[1].length
    assert_match(/…\z/, loaded.legs[1])
    refute_includes File.read(first["path"]), "Forma"
    refute_includes File.read(first["path"]), "slow down"

    again = teacher.teach(app: "", host: nil, goal: "Find stays tonight", legs: [" Search again."],
                          existing_id: first["id"])
    updated = store.find(first["id"])
    assert_equal 2, again["version"]
    assert_equal ["Safari"], updated.apps
    assert_equal ["fixture.test"], updated.hosts
    assert_equal ["Search again."], updated.legs
  end

  def test_teaching_refuses_a_secret_and_an_empty_goal
    teacher = Wrangle::SkillTeacher.new(Wrangle::SkillStore.new(dir: @dir))

    assert_raises(Wrangle::SkillInvalid) do
      teacher.teach(app: "Finder", host: nil, goal: "Set password=hunter2", legs: ["Set password=hunter2"])
    end
    assert_raises(Wrangle::SkillInvalid) do
      teacher.teach(app: "Finder", host: nil, goal: "   ", legs: [" Overall goal: copied"])
    end
    saved = teacher.teach(app: "Finder", host: nil, goal: "Open Search", legs: [" Overall goal: copied page"])
    assert_equal ["Open Search"], Wrangle::SkillStore.new(dir: @dir).find(saved["id"]).legs
  end

  def test_prepare_leaves_an_explicit_plan_and_a_miss_on_the_explore_path
    store = Wrangle::SkillStore.new(dir: @dir)
    store.save(build_skill(legs: ["Open the stays search."]))
    asker = ->(*) { raise "the model was asked" }

    planned = { "goal" => "Find stays", "plan" => ["Caller plan"] }
    explicit = Wrangle::SkillRun.prepare(planned, store:, app: "Safari", host: "fixture.test", asker:)
    assert_equal "explicit_plan", explicit.resolution.source
    assert_equal ["Caller plan"], explicit.plan

    skipped = { "goal" => "Find stays", "no_skill" => true }
    disabled = Wrangle::SkillRun.prepare(skipped, store:, app: "Safari", host: "fixture.test", asker:)
    assert_equal "disabled", disabled.resolution.source
    assert_equal ["Find stays"], disabled.plan

    empty_store = Wrangle::SkillStore.new(dir: File.join(@dir, "empty"))
    empty = Wrangle::SkillRun.prepare({ "goal" => "Find stays" }, store: empty_store, app: "Safari", host: nil, asker:)
    assert_equal "none", empty.resolution.source
    assert_equal ["Find stays"], empty.plan
    assert_empty empty.request.fetch("plan", [])
  end

  def test_prepare_applies_one_clear_skill_and_records_a_declined_choice
    store = Wrangle::SkillStore.new(dir: @dir)
    store.save(build_skill(legs: ["Open the stays search.", "Confirm the results."], hosts: ["fixture.test"],
                           apps: ["Safari"]))
    applied = Wrangle::SkillRun.prepare({ "goal" => "Find stays" }, store:, app: "Safari", host: "fixture.test",
                                                                    asker: ->(*) { raise "clear matches do not ask" })

    assert applied.resolution.applied?
    assert_equal 2, applied.plan.length
    assert_includes applied.plan.last, "authoritative"
    assert_equal applied.plan, applied.request["plan"]

    store.save(build_skill(id: "finder-other", apps: ["Safari"], hosts: ["fixture.test"], goal_terms: %w[find stays]))
    declined = Wrangle::SkillRun.prepare(
      { "goal" => "Find stays" }, store:, app: "Safari", host: "fixture.test",
                                  asker: ->(_state, criteria, _rules) { skill_answer("none", criteria.keys) }
    )
    assert_equal "declined", declined.resolution.source
    assert_equal ["Find stays"], declined.plan
  end

  def test_teaching_is_recorded_only_after_success_and_a_save_failure_keeps_the_result
    store = Wrangle::SkillStore.new(dir: @dir)
    prepared = Wrangle::SkillRun.prepare({ "goal" => "Find stays" }, store:, app: "Safari", host: nil, asker: nil)
    page = { "url" => "https://www.fixture.test/stays", "title" => "Forma", "text" => "Find a place to slow down" }

    missed = Wrangle::SkillRun.complete({ "stopped" => "BLOCKED", "goal" => "Find stays" }, prepared, store:, page:,
                                                                                                      teach: true)
    refute missed.key?("taught")
    unproven = Wrangle::SkillRun.complete({ "stopped" => "DONE", "proven" => false, "goal" => "Find stays" }, prepared,
                                          store:, page:, teach: true)
    refute unproven.key?("taught")
    assert_empty Dir.children(@dir)

    taught = Wrangle::SkillRun.complete({ "status" => "done" }, prepared, store:, page:, teach: true,
                                                                          goal: "Find stays")
    assert taught.dig("taught", "saved")
    body = File.read(taught.dig("taught", "path"))
    assert_includes body, "fixture.test"
    refute_includes body, "Forma"
    refute_includes body, "slow down"

    secret_summary = { "stopped" => "DONE", "goal" => "Set password=hunter2" }
    secret = Wrangle::SkillRun.complete(secret_summary, prepared, store:, page: nil, teach: true)
    assert_equal false, secret.dig("taught", "saved")
    broken = Object.new
    broken.define_singleton_method(:find) { |*| nil }
    broken.define_singleton_method(:save) { |*| raise Errno::EACCES, "denied" }
    failed = Wrangle::SkillRun.teach_now(prepared, "Find stays", broken, nil)
    assert_equal false, failed["saved"]
    assert_match(/denied/, failed["error"])
  end

  def test_an_explicit_plan_is_what_gets_taught_and_empty_plan_entries_are_dropped
    store = Wrangle::SkillStore.new(dir: @dir)
    request = { "goal" => "Find stays", "plan" => ["", "Caller plan"] }
    asker = ->(*) { raise "explicit plans do not ask" }
    prepared = Wrangle::SkillRun.prepare(request, store:, app: "Safari", host: "fixture.test", asker:)
    done = { "stopped" => "DONE", "goal" => "Find stays" }
    taught = Wrangle::SkillRun.complete(done, prepared, store:, page: nil, teach: true)

    assert_equal ["Caller plan"], prepared.plan
    assert_includes File.read(taught.dig("taught", "path")), "Caller plan"
  end

  def test_a_skill_without_a_surface_or_a_host_cannot_be_applied
    bare = Wrangle::UiSkill.new(
      id: "finder-open", version: 1, title: "to", summary: "Open it.", apps: [], hosts: [],
      goal_terms: [], legs: ["Open."], source: "teach"
    )
    missing = document
    missing.delete("match")

    refute bare.surface_match?(app: "Finder", host: "fixture.test")
    assert_in_delta 0.0, bare.overlap("Find stays")
    assert_nil Wrangle::UiSkill.host_of("notaurl")
    error = assert_raises(Wrangle::SkillInvalid) { Wrangle::UiSkill.from_h(missing) }
    assert_match(/app or a host/, error.message)
    numeric = document("match" => { "goal_terms" => [1] })
    error = assert_raises(Wrangle::SkillInvalid) { Wrangle::UiSkill.from_h(numeric) }
    assert_match(/must be strings/, error.message)
  end

  def test_the_store_skips_a_directory_an_outside_path_and_a_failed_write
    store = Wrangle::SkillStore.new(dir: @dir)
    Dir.mkdir(File.join(@dir, "notes.json"))
    store.send(:read_one, "/etc/hosts")
    assert_includes store.skipped.map { |item| item["reason"] }, "outside store"
    store.load
    assert_includes store.skipped.map { |item| item["reason"] }, "not a file"
    assert_raises(Wrangle::SkillInvalid) { store.send(:safe_path, "../etc") }

    blocked = build_skill(id: "blocked-save")
    Dir.mkdir(File.join(@dir, "blocked-save.json"))
    assert_raises(SystemCallError) { store.save(blocked) }
    refute(Dir.children(@dir).any? { |name| name.end_with?(".tmp") })
  end

  def test_teaching_without_an_app_keeps_a_host_and_does_not_invent_one
    teacher = Wrangle::SkillTeacher.new(Wrangle::SkillStore.new(dir: @dir))
    saved = teacher.teach(app: "", host: "fixture.test", goal: "Find stays", legs: ["Search."])

    loaded = Wrangle::SkillStore.new(dir: @dir).find(saved["id"])
    assert_empty loaded.apps
    assert_equal ["fixture.test"], loaded.hosts
  end

  private

  def reject_documents(cases)
    cases.each do |doc, message|
      error = assert_raises(Wrangle::SkillInvalid) { Wrangle::UiSkill.from_h(doc) }
      assert_match message, error.message
    end
  end

  def identity_rejections
    {
      [] => /JSON object/,
      document("schema" => "nope") => /schema/,
      document("selectors" => ["#book"]) => /Unknown skill fields/,
      document("match" => []) => /match must be an object/,
      document("match" => { "css" => "a" }) => /Unknown match fields/,
      document("legs" => ["password=hunter2"]) => /secret assignment/,
      document("id" => "../etc") => /lowercase token/,
      document("version" => 0) => /positive integer/,
      document("version" => "1") => /positive integer/,
      document("title" => "") => /title/,
      document("title" => "x" * 81) => /title/,
      document("summary" => 1) => /string/,
      document("source" => "scrape") => /source/,
      document("taught_at" => "yesterday") => /ISO-8601/,
      document("fingerprint" => "abcd") => /12 hex/
    }
  end

  def match_rejections
    long_host = "#{"a" * 90}.com"
    {
      document("stop" => "x" * 241) => /too long/,
      document("match" => { "apps" => "Finder" }) => /must be a list/,
      document("match" => { "apps" => ["Finder"] * 9 }) => /too many/,
      document("match" => { "apps" => [1] }) => /must be strings/,
      document("match" => { "apps" => ["a" * 81] }) => /must be short/,
      document("match" => { "hosts" => [long_host] }) => /must be short/,
      document("match" => { "goal_terms" => "open" }) => /goal_terms/,
      document("match" => { "goal_terms" => ["open"] * 13 }) => /too many/,
      document("match" => { "goal_terms" => ["No"] }) => /short tokens/,
      document("legs" => []) => /procedure legs/,
      document("legs" => ["x" * 241]) => /skill leg/,
      document("match" => { "apps" => [], "hosts" => [] }) => /app or a host/
    }
  end

  def normalized_document
    document(
      "match" => { "hosts" => ["WWW.Example.COM"], "goal_terms" => ["Open"] },
      "source" => "manual", "stop" => "   "
    )
  end

  def build_skill(**overrides)
    attrs = {
      id: "finder-open", version: 1, title: "Open the window", summary: "Open the stays search.",
      apps: ["Finder"], hosts: [], goal_terms: [], legs: ["Open the stays search."], stop: "Search is visible."
    }.merge(overrides)
    Wrangle::UiSkill.build(**attrs)
  end

  def document(overrides = {})
    {
      "schema" => Wrangle::UiSkill::SCHEMA, "id" => "finder-open", "version" => 1,
      "title" => "Open search", "summary" => "Open the search window.",
      "match" => { "apps" => ["Finder"], "hosts" => [], "goal_terms" => ["open"] },
      "legs" => ["Open Search."], "stop" => "Search is visible.", "source" => "teach",
      "fingerprint" => "abc123abc123"
    }.merge(overrides)
  end

  def choose_with(store, answer)
    Wrangle::SkillChooser.new(store:, asker: ->(*) { answer }).choose(app: "Finder", host: nil,
                                                                      goal: "Open the search window")
  end

  def distribution(probabilities, confidence: 0.8, choice: "finder-a")
    { "choice" => choice, "confidence" => confidence, "probabilities" => probabilities }
  end

  def skill_answer(choice, keys, confidence: 0.8, mass: 0.8)
    rest = keys - [choice]
    share = rest.empty? ? 0.0 : (1.0 - mass) / rest.length
    {
      "choice" => choice, "confidence" => confidence,
      "probabilities" => keys.to_h { |key| [key, key == choice ? mass : share] }
    }
  end
end

class SkillRunSessionTest < Minitest::Test
  parallelize_me!
  include BridgeHelpers

  def setup
    super
    @socket = File.join(@tmpdir, "skills.sock")
    @skills = File.join(@tmpdir, "skills")
  end

  def teardown
    thread = @thread
    @thread = nil
    thread&.kill
    thread&.join(1)
    super
  end

  def test_a_clear_skill_becomes_the_plan_and_teaching_does_not_copy_the_page
    save_safari_skill(legs: ["Open the stays search.", "Confirm the results are visible."])
    value = run_goal(scripted({ operation: "DONE", confidence: 0.9 }, { operation: "DONE", confidence: 0.9 }),
                     teach: true)

    assert_equal "DONE", value["stopped"]
    assert_equal "fixture-stays", value.dig("skill", "id")
    assert_equal "clear", value.dig("skill", "source")
    assert_equal 2, value["legs"]
    assert_includes @jev.asked.first[:goal], "Open the stays search."
    assert_includes @jev.asked.last[:goal], "authoritative"
    assert_equal 2, value.dig("taught", "version")
    saved = File.read(value.dig("taught", "path"))
    refute_includes saved, "Forma"
    refute_includes saved, "slow down"
    refute_includes saved, "Overall goal:"
  end

  def test_an_explicit_plan_a_weak_skill_and_no_skill_all_explore
    save_safari_skill(goal_terms: ["reservation"], legs: ["Book the reservation."], fingerprint: nil)

    planned = run_goal(scripted({ operation: "DONE", confidence: 0.9 }), plan: ["Caller plan"])
    assert_equal "explicit_plan", planned.dig("skill", "source")
    assert_equal "Caller plan", @jev.asked.first[:goal]

    weak = run_goal(scripted({ operation: "DONE", confidence: 0.9 }), goal: "Find stays")
    assert_equal "weak", weak.dig("skill", "source")
    assert_equal "Find stays", @jev.asked.first[:goal]

    skipped = run_goal(scripted({ operation: "DONE", confidence: 0.9 }), no_skill: true)
    assert_equal "disabled", skipped.dig("skill", "source")
    assert_equal ["Find stays"], @jev.asked.map { |ask| ask[:goal] }.uniq
  end

  def test_a_wrong_host_does_not_apply_and_a_blocked_run_is_not_taught
    save_safari_skill(hosts: ["example.test"])
    value = run_goal(scripted(*([{ operation: "BLOCKED", confidence: 0.9 }] * 4)), teach: true)

    assert_equal "none", value.dig("skill", "source")
    assert_equal "BLOCKED", value["stopped"]
    refute value.key?("taught")
    assert_equal "Find stays", @jev.asked.first[:goal]
  end

  def test_jev_may_choose_only_an_offered_skill_id
    save_safari_skill(id: "fixture-a", goal_terms: %w[find stays], legs: ["Use the first procedure."])
    save_safari_skill(id: "fixture-b", goal_terms: %w[find stays], legs: ["Use the second procedure."])
    jev = ChoosingJev.new("fixture-b", [{ operation: "DONE", confidence: 0.9 }])
    value = run_goal(jev)

    assert_equal "choice", value.dig("skill", "source")
    assert_equal "fixture-b", value.dig("skill", "id")
    assert_includes jev.skill_questions.first["criteria"].keys, "none"
    assert_equal %w[app goal host], jev.skill_questions.first["state"].keys.sort
    refute_includes JSON.generate(jev.skill_questions), "Forma"
    assert_includes @jev.asked.first[:goal], "Use the second procedure."
  end

  def test_an_invented_skill_id_is_rejected_and_the_run_explores
    save_safari_skill(id: "fixture-a", goal_terms: %w[find stays])
    save_safari_skill(id: "fixture-b", goal_terms: %w[find stays])
    value = run_goal(ChoosingJev.new("invented", [{ operation: "DONE", confidence: 0.9 }]))

    assert_equal "rejected", value.dig("skill", "source")
    assert_equal false, value.dig("skill", "applied")
    assert_equal "Find stays", @jev.asked.first[:goal]
  end

  def test_explore_teach_records_the_host_and_not_the_page_text
    value = run_goal(scripted({ operation: "DONE", confidence: 0.9 }), teach: true)

    assert value.dig("taught", "saved")
    body = File.read(value.dig("taught", "path"))
    assert_includes body, "fixture.test"
    assert_includes body, "Safari"
    refute_includes body, "Forma"
    refute_includes body, "Find a place to slow down"
  end

  private

  def serving(jev)
    stop_server
    @socket = File.join(@tmpdir, "skills-#{SecureRandom.hex(4)}.sock")
    @jev = jev
    server = Wrangle::SessionServer.new(@socket, {}, session: dedicated, jev:, timing: @clock)
    @thread = Thread.new { server.run }
    @thread.report_on_exception = false
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    sleep 0.02 until File.socket?(@socket) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    flunk "session socket was not created at #{@socket}" unless File.socket?(@socket)
    Wrangle::SessionClient.new(@socket)
  end

  def stop_server
    thread = @thread
    @thread = nil
    thread&.kill
    thread&.join(1)
  end

  def run_goal(jev, goal: "Find stays", **params)
    client = serving(jev)
    reply = client.call("run", goal:, execute: true, settle: 0, steady: 0.0, skills_dir: @skills, **params)
    assert reply["ok"], reply["error"]
    reply.fetch("value")
  end

  def scripted(*turns) = ScriptedJev.new(turns, sleeper: @clock.method(:sleep))

  def save_safari_skill(id: "fixture-stays", legs: ["Open the stays search."], hosts: ["fixture.test"],
                        goal_terms: %w[find stays], fingerprint: Wrangle::UiSkill.fingerprint("Find stays"))
    Wrangle::SkillStore.new(dir: @skills).save(
      Wrangle::UiSkill.build(
        id:, version: 1, title: "Find stays", summary: "Open the stays search.",
        apps: ["Safari"], hosts:, goal_terms:, legs:, stop: "The results are visible.",
        fingerprint:
      )
    )
  end
end

# Answers the skill question itself so the action script is not consumed by the lookup.
class ChoosingJev
  attr_reader :skill_questions

  def initialize(choice, turns)
    @choice = choice
    @inner = ScriptedJev.new(turns)
    @skill_questions = []
  end

  def asked = @inner.asked

  def ask(state:, questions:)
    return skill_reply(questions.fetch("skill"), state) if questions.key?("skill")

    @inner.ask(state:, questions:)
  end

  private

  def skill_reply(question, state)
    criteria = question.fetch("criteria")
    @skill_questions << { "criteria" => criteria, "state" => state }
    keys = criteria.keys
    mass_choice = keys.include?(@choice) ? @choice : keys.first
    rest = keys - [mass_choice]
    share = rest.empty? ? 0.0 : 0.2 / rest.length
    probabilities = keys.to_h { |key| [key, key == mass_choice ? 0.8 : share] }
    { "answers" => { "skill" => { "choice" => @choice, "confidence" => 0.8, "probabilities" => probabilities } } }
  end
end
