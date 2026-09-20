# frozen_string_literal: true

require "digest"
require "json"
require "time"

require_relative "decision_provider"

module Wrangle
  # Runs deterministic recorded choice cases before a provider is eligible for desktop mutation.
  class ProviderQualification
    SCHEMA = "wrangle.provider-case.v1"
    REPORT_SCHEMA = "wrangle.provider-qualification.v1"
    DEFAULT_SUITE = File.expand_path("provider_conformance.jsonl", __dir__)
    MAX_SUITE_BYTES = 256 * 1024
    MAX_CASES = 128
    REPORT_TTL = 7 * 24 * 60 * 60

    def self.load(path = DEFAULT_SUITE)
      raise ConfigurationError, "Provider suite must be a regular file" unless File.file?(path)
      raise ConfigurationError, "Provider suite is too large" if File.size(path) > MAX_SUITE_BYTES

      cases = File.foreach(path).reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
      valid_count = cases.length.between?(1, MAX_CASES)
      raise ConfigurationError, "Provider suite must contain 1..#{MAX_CASES} cases" unless valid_count

      cases
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError => e
      raise ConfigurationError, "Could not load provider suite: #{e.class}"
    end

    def self.default_suite_digest = suite_digest(load)

    def self.run(provider, cases)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      results = cases.map { |test_case| check(provider, test_case) }
      {
        "schema" => REPORT_SCHEMA, "at" => Time.now.utc.iso8601,
        "provider" => provider.capabilities.provider, "model" => provider.capabilities.model,
        "runtime" => provider.capabilities.runtime, "transport" => provider.capabilities.transport,
        "protocol" => provider.capabilities.protocol, "suite_sha256" => suite_digest(cases),
        "cases" => results.length, "passed" => results.count { |result| result["passed"] },
        "qualified" => results.all? { |result| result["passed"] },
        "elapsed_ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1),
        "results" => results
      }
    end

    def self.check(provider, test_case)
      raise ArgumentError, "Unknown provider conformance case" unless test_case["schema"] == SCHEMA

      request = test_case.fetch("request")
      decision = provider.choose(
        state: request.fetch("state"), name: request.fetch("name"),
        criteria: request.fetch("criteria"), instructions: request.fetch("instructions")
      )
      { "name" => request.fetch("name"), "expected" => test_case.fetch("expected"),
        "actual" => decision.choice, "passed" => decision.choice == test_case.fetch("expected"),
        "latency_ms" => decision.latency_ms }
    rescue Error, ArgumentError, KeyError => e
      { "name" => test_case.dig("request", "name"), "expected" => test_case["expected"],
        "actual" => nil, "passed" => false, "error" => e.class.name.split("::").last }
    end
    private_class_method :check

    def self.suite_digest(cases)
      Digest::SHA256.hexdigest(JSON.generate(cases))
    end
    private_class_method :suite_digest
  end
end
