# frozen_string_literal: true

require_relative "test_helper"

class ProviderFactoryTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("wrangle-provider")
    @trace = File.join(@directory, "trace.jsonl")
    File.write(@trace, "")
  end

  def teardown
    FileUtils.remove_entry(@directory) if File.directory?(@directory)
  end

  def test_builds_only_the_explicit_replay_provider
    provider = Wrangle::ProviderFactory.build("provider" => "replay", "provider_trace" => @trace)

    assert_equal "replay", provider.capabilities.provider
    assert_match(/\Arecorded-sha256:[0-9a-f]{64}\z/, provider.capabilities.model)
    refute provider.mutation_qualified?

    pinned = Wrangle::ProviderFactory.build(
      "provider" => "replay", "provider_trace" => @trace,
      "provider_model" => provider.capabilities.model
    )
    assert_equal provider.capabilities.model, pinned.capabilities.model
  end

  def test_builds_the_explicit_jev_provider_without_contacting_it
    previous = ENV.fetch("JEV_API_KEY", nil)
    ENV["JEV_API_KEY"] = "test-only"
    provider = Wrangle::ProviderFactory.build(
      "provider" => "jev", "provider_model" => "fixture-model",
      "provider_endpoint" => "http://127.0.0.1:1/choice"
    )

    assert_equal "remote", provider.capabilities.runtime
    assert_equal "http", provider.capabilities.transport
    assert_equal "fixture-model", provider.capabilities.model
  ensure
    ENV["JEV_API_KEY"] = previous
  end

  def test_jev_provider_records_the_default_model_when_optional_configuration_is_absent
    previous = ENV.fetch("JEV_API_KEY", nil)
    ENV["JEV_API_KEY"] = "test-only"

    [{}, { "provider_model" => nil }, { "provider_model" => "" }].each do |optional|
      provider = Wrangle::ProviderFactory.build({ "provider" => "jev" }.merge(optional))
      assert_equal Wrangle::Jev::DEFAULT_MODEL, provider.capabilities.model
    end
  ensure
    ENV["JEV_API_KEY"] = previous
  end

  def test_accepts_a_matching_explicit_qualification_receipt
    receipt = File.join(@directory, "qualification.json")
    model = Wrangle::ProviderFactory.build(
      "provider" => "replay", "provider_trace" => @trace
    ).capabilities.model
    File.write(receipt, JSON.generate(
                          "schema" => "wrangle.provider-qualification.v1", "qualified" => true,
                          "at" => Time.now.utc.iso8601, "protocol" => Wrangle::DecisionProvider::PROTOCOL,
                          "provider" => "replay", "model" => model,
                          "suite_sha256" => Wrangle::ProviderQualification.default_suite_digest
                        ))
    provider = Wrangle::ProviderFactory.build(
      "provider" => "replay", "provider_trace" => @trace, "provider_qualification" => receipt
    )

    assert provider.mutation_qualified?
  end

  def test_refuses_unknown_or_unconfigured_providers
    assert_raises(Wrangle::ConfigurationError) do
      Wrangle::ProviderFactory.build("provider" => "other")
    end
    assert_raises(Wrangle::ConfigurationError) do
      Wrangle::ProviderFactory.build("provider" => "replay")
    end
    assert_raises(Wrangle::ConfigurationError) do
      Wrangle::ProviderFactory.build(
        "provider" => "replay", "provider_trace" => @trace, "provider_model" => "unbound"
      )
    end
  end

  def test_expired_qualification_receipt_does_not_qualify
    receipt = File.join(@directory, "qualification.json")
    model = Wrangle::ProviderFactory.build(
      "provider" => "replay", "provider_trace" => @trace
    ).capabilities.model
    File.write(receipt, JSON.generate(
                          "schema" => Wrangle::ProviderQualification::REPORT_SCHEMA,
                          "qualified" => true, "at" => (Time.now.utc - (8 * 24 * 60 * 60)).iso8601,
                          "protocol" => Wrangle::DecisionProvider::PROTOCOL,
                          "provider" => "replay", "model" => model,
                          "suite_sha256" => Wrangle::ProviderQualification.default_suite_digest
                        ))

    provider = Wrangle::ProviderFactory.build(
      "provider" => "replay", "provider_trace" => @trace, "provider_qualification" => receipt
    )
    refute provider.mutation_qualified?
  end

  def test_malformed_or_mismatched_receipt_does_not_qualify
    receipt = File.join(@directory, "qualification.json")
    File.write(receipt, "not json")
    provider = Wrangle::ProviderFactory.build(
      "provider" => "replay", "provider_trace" => @trace, "provider_qualification" => receipt
    )
    refute provider.mutation_qualified?

    model = Wrangle::ProviderFactory.build(
      "provider" => "replay", "provider_trace" => @trace
    ).capabilities.model
    File.write(receipt, JSON.generate("schema" => "wrangle.provider-qualification.v1", "qualified" => true,
                                      "at" => Time.now.utc.iso8601,
                                      "protocol" => Wrangle::DecisionProvider::PROTOCOL,
                                      "provider" => "other", "model" => model,
                                      "suite_sha256" => Wrangle::ProviderQualification.default_suite_digest))
    provider = Wrangle::ProviderFactory.build(
      "provider" => "replay", "provider_trace" => @trace, "provider_qualification" => receipt
    )
    refute provider.mutation_qualified?
  end
end
