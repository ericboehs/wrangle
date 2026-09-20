# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/fake_typesafe"

# The only place Wrangle talks to a network. These run against a real HTTP server on a real socket,
# because everything worth checking here is a property of the transport: a 429 that must be retried,
# a connection that opens and then says nothing, a body that is not the JSON object it claimed.
class JevTest < Minitest::Test
  parallelize_me!
  OK_BODY = JSON.generate("answers" => { "operation" => { "answer" => "CLICK" } }, "model" => "jev-test")

  def teardown
    @fake&.stop
    super
  end

  def asking(script, **)
    @fake = FakeTypeSafe.new(script)
    Wrangle::Jev.new(api_key: "test-key", endpoint: @fake.endpoint,
                     timing: (@clock ||= AcceleratedClock.new), **)
  end

  def ask(jev) = jev.ask(state: { "url" => "https://fixture.test" }, questions: { "operation" => %w[CLICK DONE] })

  # --- the happy path ---------------------------------------------------------------------------

  def test_an_answer_comes_back_parsed
    answer = ask(asking([[200, OK_BODY]]))

    assert_equal "jev-test", answer["model"]
    assert_equal "CLICK", answer.dig("answers", "operation", "answer")
  end

  def test_the_request_carries_the_key_the_model_and_the_question
    ask(asking([[200, OK_BODY]]))
    request = @fake.requests.fetch(0)

    assert_equal "Bearer test-key", request["headers"]["authorization"]
    assert_equal "application/json", request["headers"]["content-type"]
    assert_match(%r{\Awrangle/}, request["headers"]["user-agent"])
    assert_equal "POST /v1/systemone HTTP/1.1", request["request_line"]

    sent = JSON.parse(request["body"])

    assert_equal "jev-latest", sent["model"]
    assert_equal "https://fixture.test", sent.dig("state", "url")
    assert_equal %w[CLICK DONE], sent.dig("questions", "operation")
  end

  def test_the_model_is_the_one_it_was_built_with
    ask(asking([[200, OK_BODY]], model: "jev-1.13.0"))

    assert_equal "jev-1.13.0", JSON.parse(@fake.requests.fetch(0)["body"])["model"]
  end

  # --- what the far end can do wrong ------------------------------------------------------------

  def test_an_http_error_is_reported_with_its_status
    error = assert_raises(Wrangle::JevError) { ask(asking([[500, "upstream exploded"]])) }

    assert_equal "http_500", error.code
    assert_match(/HTTP 500/, error.message)
  end

  def test_a_body_that_is_not_json_is_refused
    error = assert_raises(Wrangle::JevError) { ask(asking([[200, "<html>gateway</html>"]])) }

    assert_equal "bad_response", error.code
    assert_match(/invalid JSON/, error.message)
  end

  # Valid JSON is not the same as a valid answer. A bare array parses and then fails on every `dig`
  # far away from here, so it is rejected at the boundary.
  def test_json_that_is_not_an_object_is_refused
    ["[1, 2, 3]", '"a string"', "42", "null"].each do |body|
      error = assert_raises(Wrangle::JevError) { ask(asking([[200, body]])) }

      assert_equal "bad_response", error.code, "#{body} should not be accepted as an answer"
    end
  end

  # --- retrying ---------------------------------------------------------------------------------

  def test_a_rate_limit_is_retried_and_the_answer_is_still_returned
    answer = ask(asking([[429, "slow down"], [200, OK_BODY]]))

    assert_equal "jev-test", answer["model"]
    assert_equal 2, @fake.requests.length
  end

  def test_an_overloaded_model_is_retried_too
    answer = ask(asking([[529, "overloaded"], [200, OK_BODY]]))

    assert_equal "jev-test", answer["model"]
    assert_equal 2, @fake.requests.length
  end

  # Three attempts, then the status is reported rather than retried forever.
  def test_retrying_gives_up_and_reports_the_status
    error = assert_raises(Wrangle::JevError) { ask(asking([[429, "slow down"]])) }

    assert_equal "http_429", error.code
    assert_equal 3, @fake.requests.length
  end

  def test_an_error_that_is_not_retryable_is_not_retried
    assert_raises(Wrangle::JevError) { ask(asking([[503, "unavailable"]])) }

    assert_equal 1, @fake.requests.length
  end

  # --- the transport ----------------------------------------------------------------------------

  def test_a_server_that_never_answers_times_out
    error = assert_raises(Wrangle::JevError) { ask(asking([:silence], timeout: 0.2)) }

    assert_equal "timeout", error.code
  end

  def test_a_server_that_is_not_there_is_unreachable
    fake = FakeTypeSafe.new([[200, OK_BODY]])
    endpoint = fake.endpoint
    fake.stop # The port is now closed, so connecting to it is refused.
    jev = Wrangle::Jev.new(api_key: "k", endpoint: endpoint, timeout: 1)

    error = assert_raises(Wrangle::JevError) { ask(jev) }

    assert_equal "unreachable", error.code
    assert_match(/Could not reach Jev/, error.message)
  end

  def test_a_response_too_large_to_hold_is_refused
    body = JSON.generate("pad" => "x" * (Wrangle::Jev::MAX_RESPONSE_BYTES + 1))
    error = assert_raises(Wrangle::JevError) { ask(asking([[200, body]], timeout: 10)) }

    assert_equal "oversized", error.code
  end
end

# Environment mutation is process-global, so configuration examples remain serial while transport
# tests run in parallel against their own sockets.
class JevEnvironmentTest < Minitest::Test
  def with_env(values)
    saved = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end

  def test_the_key_comes_from_either_name
    with_env("JEV_API_KEY" => "from-jev", "TYPESAFE_API_KEY" => nil) do
      assert_instance_of Wrangle::Jev, Wrangle::Jev.from_env
    end
    with_env("JEV_API_KEY" => nil, "TYPESAFE_API_KEY" => "from-typesafe") do
      assert_instance_of Wrangle::Jev, Wrangle::Jev.from_env
    end
  end

  def test_no_key_at_all_says_which_variable_to_set
    with_env("JEV_API_KEY" => nil, "TYPESAFE_API_KEY" => nil) do
      error = assert_raises(Wrangle::ConfigurationError) { Wrangle::Jev.from_env }

      assert_match(/JEV_API_KEY/, error.message)
    end
  end

  # An empty variable is the shape a missing key usually arrives in — `export JEV_API_KEY=` in a
  # shell profile, or a CI secret that was never populated. It is missing, not set.
  def test_an_empty_key_counts_as_missing
    with_env("JEV_API_KEY" => "", "TYPESAFE_API_KEY" => "") do
      assert_raises(Wrangle::ConfigurationError) { Wrangle::Jev.from_env }
    end
  end

  def test_the_endpoint_and_model_come_from_the_environment_and_arguments_win
    with_env("JEV_API_KEY" => "k", "JEV_ENDPOINT" => "https://elsewhere.test/v1", "JEV_MODEL" => "jev-env") do
      from_env = Wrangle::Jev.from_env

      assert_equal "https://elsewhere.test/v1", from_env.endpoint.to_s
      assert_equal "jev-env", from_env.model

      explicit = Wrangle::Jev.from_env(endpoint: "https://given.test/v1", model: "jev-given")

      assert_equal "https://given.test/v1", explicit.endpoint.to_s
      assert_equal "jev-given", explicit.model
    end
  end

  def test_the_defaults_are_typesafe_when_nothing_says_otherwise
    with_env("JEV_API_KEY" => "k", "JEV_ENDPOINT" => nil, "JEV_MODEL" => nil) do
      jev = Wrangle::Jev.from_env

      assert_equal Wrangle::Jev::DEFAULT_ENDPOINT, jev.endpoint.to_s
      assert_equal Wrangle::Jev::DEFAULT_MODEL, jev.model
    end
  end
end
