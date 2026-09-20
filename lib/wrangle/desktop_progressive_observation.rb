# frozen_string_literal: true

module Wrangle
  # Escalates a bounded AX skeleton to a deeper root-window observation before an autonomous action.
  # The provider must re-decide from the completed state; target choices never cross this boundary.
  module DesktopProgressiveObservation
    private

    def escalate_observation?
      return false if @view

      previous = current
      started = monotonic
      @observation = @driver.observe(@scope, skeleton: false)
      @full_observation = true
      @proposals.clear
      fields = {
        "scope_id" => @scope.id, "revision" => @observation["revision"],
        "previous_revision" => previous["revision"], "complete" => @observation["complete"],
        "candidates" => @observation["candidates"].length,
        "ambiguous_actions" => @observation.dig("coverage", "ambiguous_action_count"),
        "elapsed_ms" => elapsed_ms(started)
      }
      @log&.record("observe_escalated", fields)
      true
    end

    def fresh_observation
      return @driver.drill(@scope, **@view) if @view

      @driver.observe(@scope, skeleton: !@full_observation)
    end
  end
end
