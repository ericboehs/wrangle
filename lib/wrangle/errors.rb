# frozen_string_literal: true

module Wrangle
  # Every failure here is deliberate. Nothing in this library guesses, retries a mutation, or
  # looks for a replacement window when the one it was given is gone.
  class Error < StandardError; end

  # The osascript bridge could not complete a request.
  class BridgeError < Error; end

  # A bridge request exceeded its deadline.
  class BridgeTimeout < BridgeError; end

  # The bridge refused a request and named the reason.
  class BridgeCallError < BridgeError
    # Codes the bridge can return: safari_not_running, window_gone, scope_changed, bad_request,
    # javascript_failed, bad_result, open_failed, bridge_error.
    SCOPE_CODES = %w[window_gone scope_changed].freeze

    attr_reader :code

    def initialize(code, message)
      super("#{code}: #{message}")
      @code = code
    end

    def scope? = SCOPE_CODES.include?(code)
  end

  # A platform driver is absent, incompatible, or returned a malformed response.
  class DriverError < Error; end

  class DriverUnavailable < DriverError; end
  class DriverTimeout < DriverError; end

  # A platform driver refused an operation. Delivery and retry are separate because an action that
  # may have landed is terminal even when the driver thinks another attempt might succeed.
  class DriverRefusal < DriverError
    attr_reader :code, :delivery, :retry_disposition, :suggestion, :details

    def initialize(code, message, delivery: nil, retry_disposition: nil, suggestion: nil, details: nil)
      super("#{code}: #{message}")
      @code = code
      @delivery = delivery
      @retry_disposition = retry_disposition
      @suggestion = suggestion
      @details = details
    end

    def delivery_unknown? = delivery == "unknown"
    def safe_to_retry? = delivery == "not_delivered" && retry_disposition == "safe"
  end

  # Another exclusive session already controls an overlapping root surface.
  class ScopeBusy < Error; end

  # A progressive observation has unresolved branches and cannot safely authorize mutation.
  class PartialObservation < Error; end

  # Deterministic policy denied an otherwise observed action.
  class PolicyDenied < Error; end

  # The bound window, tab, or document is no longer the one this session was handed.
  # A new explicit handoff is required; the session will not look for a substitute.
  class ScopeLost < Error; end

  # A mutation may or may not have landed. It is never repeated to find out.
  class DeliveryUnknown < Error; end

  # A decision no longer refers to the observed page. Observe again before deciding again.
  class StalePage < Error; end

  # Raised when the decision service is unusable: unreachable, slow, or answering with something it
  # was never offered. A bad answer is a refusal, not a fallback to guessing.
  # A vendor-neutral decision provider failed negotiation or returned an invalid choice.
  class ProviderError < Error; end

  class JevError < Error
    attr_reader :code

    def initialize(message, code: nil)
      super(message)
      @code = code
    end
  end

  # Raised when Wrangle was asked to decide without the configuration to do it.
  class ConfigurationError < Error; end
end
