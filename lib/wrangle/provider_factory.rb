# frozen_string_literal: true

require "digest"

require_relative "decision_provider"
require_relative "jev"
require_relative "provider_qualification"

module Wrangle
  # Explicit provider construction. There is deliberately no fallback between local, replay, or HTTP.
  class ProviderFactory
    def self.build(options)
      name = options.fetch("provider")
      model = name == "replay" ? replay_model(options) : jev_model(options)
      transport = case name
                  when "replay" then replay(options)
                  when "jev" then jev(options, model)
                  else raise ConfigurationError, "Unknown decision provider #{name.inspect}"
                  end
      DecisionProvider.new(
        transport:,
        capabilities: {
          protocol: DecisionProvider::PROTOCOL,
          max_choices: Integer(options.fetch("provider_max_choices", 64)), confidence: true,
          hierarchical: true, mutation_qualified: qualified?(options, name, model),
          provider: name, model:, runtime: name == "replay" ? "ruby" : "remote",
          transport: name == "replay" ? "replay" : jev_transport(options)
        }
      )
    end

    def self.replay_model(options)
      path = options["provider_trace"]
      raise ConfigurationError, "Replay provider requires --provider-trace" if path.to_s.empty?

      digest = Digest::SHA256.file(path).hexdigest
      requested = options["provider_model"]
      model = "recorded-sha256:#{digest}"
      raise ConfigurationError, "Replay provider model is bound to the trace digest" if requested && requested != model

      model
    rescue Errno::ENOENT => e
      raise ConfigurationError, "Could not load replay provider trace: #{e.class}"
    end
    private_class_method :replay_model

    def self.replay(options)
      path = options["provider_trace"]
      raise ConfigurationError, "Replay provider requires --provider-trace" if path.to_s.empty?

      ReplayChoiceTransport.load(path)
    rescue Errno::ENOENT, JSON::ParserError => e
      raise ConfigurationError, "Could not load replay provider trace: #{e.class}"
    end
    private_class_method :replay

    def self.jev_model(options)
      requested = options["provider_model"].to_s
      requested.empty? ? Jev::DEFAULT_MODEL : requested
    end
    private_class_method :jev_model

    def self.jev(options, model)
      client = Jev.from_env(endpoint: options["provider_endpoint"], model:)
      JevChoiceTransport.new(client)
    end
    private_class_method :jev

    def self.jev_transport(options)
      endpoint = options["provider_endpoint"] || ENV["JEV_ENDPOINT"] || Jev::DEFAULT_ENDPOINT
      URI.parse(endpoint).scheme
    end
    private_class_method :jev_transport

    def self.qualified?(options, provider, model)
      path = options["provider_qualification"]
      return false if path.to_s.empty?

      report = JSON.parse(File.read(path, 64 * 1024))
      qualified_at = Time.iso8601(report.fetch("at"))
      age = Time.now.utc - qualified_at
      report["schema"] == ProviderQualification::REPORT_SCHEMA && report["qualified"] == true &&
        age.between?(0, ProviderQualification::REPORT_TTL) &&
        report["protocol"] == DecisionProvider::PROTOCOL && report["provider"] == provider &&
        report["model"] == model && report["suite_sha256"] == ProviderQualification.default_suite_digest
    rescue Errno::ENOENT, JSON::ParserError, KeyError, ArgumentError
      false
    end
    private_class_method :qualified?
  end
end
