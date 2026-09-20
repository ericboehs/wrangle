# frozen_string_literal: true

require_relative "desktop_effect"
require_relative "errors"

module Wrangle
  # Durable at-most-once boundary around the native call. If the process disappears after the marker
  # is synced, the next session sees unresolved delivery and refuses to substitute or retry the action.
  module DesktopDispatch
    private

    def deliver_proposal(proposal, fresh)
      candidate = revalidated_candidate!(proposal, fresh)
      dispatch = begin_durable_dispatch(proposal)
      @proposals.delete(proposal["id"])
      delivery = @driver.execute(
        @scope, operation: proposal["operation"], ref: candidate["ref"], text: proposal["text"]
      )
      return finish_undelivered(proposal, dispatch, delivery) if
        %w[not_delivered refused].include?(delivery["dispatch"])

      finish_observed_delivery(proposal, fresh, dispatch, delivery)
    rescue DeliveryUnknown => e
      @poisoned ||= e
      raise
    rescue StandardError => e
      @poisoned ||= DeliveryUnknown.new("Desktop action delivery was interrupted after durable dispatch began")
      raise @poisoned, cause: e
    end

    def begin_durable_dispatch(proposal)
      @registry.begin_dispatch(
        @scope, proposal_id: proposal["id"], revision: proposal["revision"], operation: proposal["operation"]
      )
    end

    def finish_undelivered(proposal, dispatch, delivery)
      result = receipt(proposal, delivery["dispatch"], "not_applicable", delivery["code"], durable: true)
      @registry.finish_dispatch(dispatch)
      result
    end

    def finish_observed_delivery(proposal, fresh, dispatch, delivery)
      @actions += 1
      after, verification_error = observe_after_dispatch
      observed_effect = DesktopEffect.verify(proposal, fresh, after)
      @observation = after if after
      @poisoned = DeliveryUnknown.new("Desktop action delivery is unknown") if
        delivery["dispatch"] == "delivery_unknown"
      result = receipt(
        proposal, delivery["dispatch"], observed_effect, delivery["code"],
        after:, verification_error:, durable: true
      )
      @registry.finish_dispatch(dispatch) unless delivery["dispatch"] == "delivery_unknown"
      result
    end
  end
end
