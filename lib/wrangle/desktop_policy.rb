# frozen_string_literal: true

require_relative "errors"

module Wrangle
  # Deterministic permission policy. A provider may assess risk, but cannot make this gate weaker.
  class DesktopPolicy
    CREDENTIAL = /password|passcode|verification code|one[- ]time|security code|api key|secret|token/i
    CONSEQUENCE = /\b(send|submit|delete|remove|trash|erase|buy|purchase|pay|confirm|save|allow|
                       install|quit|sign\s+out)\b/ix
    CONSEQUENTIAL_OPERATIONS = %w[TOGGLE].freeze
    WINDOW_CONTROL = /\A(?:close|close window|close all|quit(?: .*)?|minimize|zoom|full ?screen)\z/i
    WINDOW_SUBROLES = %w[closebutton minimizebutton zoombutton fullscreenbutton].freeze

    Assessment = Data.define(:classification, :consequential, :permitted, :reason) do
      def to_h
        { "classification" => classification, "consequential" => consequential,
          "permitted" => permitted, "reason" => reason }.compact
      end
    end

    def assess(scope:, candidate:, operation:)
      label = candidate["label"].to_s
      if operation == "SET_TEXT" && label.match?(CREDENTIAL)
        return Assessment.new(classification: "credential_handoff", consequential: true, permitted: false,
                              reason: "Credentials must be entered through password-manager or SSO UI")
      end
      if operation == "PRESS" && window_control?(candidate, label)
        return Assessment.new(classification: "scope_violation", consequential: true, permitted: false,
                              reason: "Wrangle never closes or manages a handed-over root window")
      end

      consequential = CONSEQUENTIAL_OPERATIONS.include?(operation) ||
                      (operation == "PRESS" && label.match?(CONSEQUENCE))
      reason = "#{scope.app} action #{label.inspect} may have an external or persistent consequence" if consequential
      Assessment.new(classification: consequential ? "consequential" : "standard",
                     consequential:, permitted: true, reason:)
    end

    private

    def window_control?(candidate, label)
      subrole = candidate["subrole"].to_s.delete_prefix("AX").downcase
      WINDOW_SUBROLES.include?(subrole) || label.match?(WINDOW_CONTROL)
    end
  end
end
