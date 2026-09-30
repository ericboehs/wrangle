# frozen_string_literal: true

require_relative "test_helper"

class ProviderQualificationTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/provider_conformance.jsonl", __dir__)

  def provider(cases)
    records = cases.map do |test_case|
      { "name" => test_case.dig("request", "name"),
        "answer" => test_case.fetch("answer") }
    end
    Wrangle::DecisionProvider.new(
      transport: Wrangle::ReplayChoiceTransport.new(records),
      capabilities: {
        protocol: Wrangle::DecisionProvider::PROTOCOL, max_choices: 8, confidence: true,
        hierarchical: true, mutation_qualified: false, provider: "fixture", model: "recorded-v1",
        runtime: "ruby", transport: "replay"
      }
    )
  end

  def test_recorded_suite_qualifies_exact_choice_behavior
    cases = Wrangle::ProviderQualification.load(FIXTURE)
    endpoint = "http://127.0.0.1:1234/v1/systemone"
    report = Wrangle::ProviderQualification.run(provider(cases), cases, endpoint:)

    assert report["qualified"]
    assert_equal endpoint, report["endpoint"]
    assert_equal 8, report["passed"]
    assert_equal 64, report["suite_sha256"].length
    assert_operator report["elapsed_ms"], :>=, 0
    assert(report["results"].all? { |result| result["passed"] })
  end

  def test_default_suite_is_bounded_and_has_a_stable_digest
    assert_equal 8, Wrangle::ProviderQualification.load.length
    assert_match(/\A[0-9a-f]{64}\z/, Wrangle::ProviderQualification.default_suite_digest)
  end

  def test_rejects_missing_empty_and_oversized_suites
    directory = Dir.mktmpdir("wrangle-suite")
    assert_raises(Wrangle::ConfigurationError) do
      Wrangle::ProviderQualification.load(File.join(directory, "missing"))
    end

    empty = File.join(directory, "empty")
    File.write(empty, "\n")
    assert_raises(Wrangle::ConfigurationError) { Wrangle::ProviderQualification.load(empty) }

    large = File.join(directory, "large")
    File.write(large, "x" * (Wrangle::ProviderQualification::MAX_SUITE_BYTES + 1))
    assert_raises(Wrangle::ConfigurationError) { Wrangle::ProviderQualification.load(large) }
  ensure
    FileUtils.remove_entry(directory) if directory && File.directory?(directory)
  end

  def test_wrong_or_malformed_cases_fail_without_aborting_the_suite
    cases = Wrangle::ProviderQualification.load(FIXTURE)
    cases.first["expected"] = "cancel"
    cases << { "schema" => "wrong", "expected" => "none" }
    report = Wrangle::ProviderQualification.run(provider(cases.first(2)), cases)

    refute report["qualified"]
    assert_equal 1, report["passed"]
    assert_equal "ArgumentError", report["results"].last["error"]
  end
end
