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

  # The bound window, tab, or document is no longer the one this session was handed.
  # A new explicit handoff is required; the session will not look for a substitute.
  class ScopeLost < Error; end

  # A mutation may or may not have landed. It is never repeated to find out.
  class DeliveryUnknown < Error; end

  # A decision no longer refers to the observed page. Observe again before deciding again.
  class StalePage < Error; end
end
