# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "errors"
require_relative "timing"

module Wrangle
  # Asks Jev to pick one observed control.
  #
  # Jev answers multiple-choice questions in a single prefill pass, which is the whole reason it is
  # worth wiring to a browser: an observation is already a numbered list of candidates. The model
  # never writes JavaScript, a selector, or a coordinate — it returns a label Wrangle offered it.
  class Jev
    DEFAULT_ENDPOINT = "https://api.typesafe.ai/v1/systemone"
    DEFAULT_MODEL = "jev-latest"
    MAX_RESPONSE_BYTES = 5 * 1024 * 1024
    RETRYABLE = [429, 529].freeze

    def self.from_env(endpoint: nil, model: nil)
      key = ENV["JEV_API_KEY"] || ENV.fetch("TYPESAFE_API_KEY", nil)
      raise ConfigurationError, "Set JEV_API_KEY (or TYPESAFE_API_KEY) to ask Jev for a decision" if key.to_s.empty?

      new(api_key: key,
          endpoint: endpoint || ENV["JEV_ENDPOINT"] || DEFAULT_ENDPOINT,
          model: model || ENV["JEV_MODEL"] || DEFAULT_MODEL)
    end

    attr_reader :model, :endpoint

    def initialize(api_key:, endpoint: DEFAULT_ENDPOINT, model: DEFAULT_MODEL, timeout: 20, timing: Timing)
      @api_key = api_key
      @endpoint = URI.parse(endpoint)
      @model = model
      @timeout = timeout
      @timing = timing
    end

    def ask(state:, questions:)
      body = JSON.generate("state" => state, "model" => @model, "questions" => questions)
      response = with_retries(body)

      unless response.code.to_i.between?(200, 299)
        raise JevError.new("Jev returned HTTP #{response.code}", code: "http_#{response.code}")
      end

      parsed = JSON.parse(response.body.to_s)
      raise JevError.new("Jev returned something that is not an object", code: "bad_response") unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError
      raise JevError.new("Jev returned invalid JSON", code: "bad_response")
    end

    private

    def with_retries(body)
      response = nil
      3.times do |attempt|
        response = post(body)
        break unless RETRYABLE.include?(response.code.to_i) && attempt < 2

        @timing.sleep(0.25 * (2**attempt))
      end
      response
    end

    def post(body)
      request = Net::HTTP::Post.new(@endpoint)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "application/json"
      request["User-Agent"] = "wrangle/#{Wrangle::VERSION}"
      request.body = body

      options = { use_ssl: @endpoint.scheme == "https", open_timeout: @timeout, read_timeout: @timeout }
      response = Net::HTTP.start(@endpoint.host, @endpoint.port, **options) { |http| http.request(request) }
      raise JevError.new("Jev response exceeded the local limit", code: "oversized") if
        response.body.to_s.bytesize > MAX_RESPONSE_BYTES

      response
    rescue Timeout::Error
      raise JevError.new("Jev timed out", code: "timeout")
    rescue SocketError, SystemCallError, IOError => e
      raise JevError.new("Could not reach Jev: #{e.class}", code: "unreachable")
    end
  end
end
