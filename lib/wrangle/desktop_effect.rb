# frozen_string_literal: true

module Wrangle
  # Independently compares post-dispatch AX state; it never trusts driver success as effect proof.
  class DesktopEffect
    def self.verify(proposal, before, after)
      return "unverified" unless after

      operation = proposal["operation"]
      return before["revision"] == after["revision"] ? "unchanged" : "verified" unless
        %w[SET_TEXT CLEAR TOGGLE].include?(operation)

      matches = after["candidates"].select do |candidate|
        candidate.values_at("role", "label") == proposal["candidate"].values_at("role", "label")
      end
      return "unverified" unless matches.one?

      if operation == "CLEAR"
        return matches.first["value"].to_s.strip.empty? ? "verified" : "unchanged"
      end
      return matches.first["value"] == proposal["text"] ? "verified" : "unchanged" if operation == "SET_TEXT"

      before_value = proposal["candidate"].slice("value", "states")
      after_value = matches.first.slice("value", "states")
      before_value == after_value ? "unchanged" : "verified"
    end
  end
end
