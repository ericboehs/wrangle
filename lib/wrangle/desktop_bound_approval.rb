# frozen_string_literal: true

require "json"

require_relative "desktop_observation"
require_relative "desktop_proposal"
require_relative "errors"

module Wrangle
  # Bound approve/decline for one consequential proposal parked in a live desktop session.
  # The agent never sees proposal_id, scope_id, revision, or pending_text; the tool strips them.
  # Receipts stay tool-facing. This path must not continue the task decision loop after a delivery.
  #
  # Terminal outcomes (the approval is spent, the lease released, and a parked task process exits):
  # delivered or any other receipt, declined, provider_not_qualified, stale_target, lost_scope,
  # expired, a driver refusal before the durable marker (not_delivered), DeliveryUnknown after it,
  # and any other failure once a matching binding has been accepted.
  #
  # Non-terminal outcomes keep the same binding live until the TTL:
  # - session_locked: retryable by contract; the person can unlock and approve again.
  # - unknown, or an echoed scope_id/revision that does not match: a request that does not hold the
  #   binding must never be able to spend (or kill) the real pending approval by guessing.
  # - request refusals (approve not literal true, rewrite fields, approve on decline): these are
  #   rejected before the binding is consulted, carry no authority, and only arise from a malformed
  #   client. Spending on them would turn a client bug into a lost approval the person gave; the tool
  #   can retry at once with the same binding, and the TTL still bounds how long the lease is held.
  # rubocop:disable-next Metrics/ModuleLength
  module DesktopBoundApproval
    FORBIDDEN_APPROVE_FIELDS = %w[operation ref text label candidate].freeze

    def parked_approval? = @parked_approval

    # Serves the existing newline-JSON socket until the parked approval resolves, the session is
    # closed, or the proposal TTL elapses. `ready` runs once the socket accepts connections.
    def serve_parked_approval(ready: nil)
      raise ArgumentError, "No parked approval to serve" unless @parked_approval && @socket_path

      listener = bind_private_socket(@socket_path)
      File.write("#{@socket_path}.pid", "#{Process.pid}\n", mode: "w", perm: 0o600)
      ready&.call
      serve(listener, deadline: parked_deadline)
      expire_parked_approval! if @parked_approval
    ensure
      @parked_approval = false
      shutdown
    end

    private

    def approve(request)
      refuse_rewrite_fields!(request)
      unless request["approve"] == true
        raise ArgumentError, "Bound approval requires approve: true; a non-true approve is not a decline"
      end

      outcome = resolve_approval_request(request)
      return outcome if outcome

      proposal = @proposals.fetch(request["proposal_id"])
      resolving_on_failure(proposal) do
        accepted = accept_bound!(proposal, request)
        next accepted if accepted

        deliver_bound_approval(proposal)
      end
    end

    def decline(request)
      refuse_rewrite_fields!(request)
      raise ArgumentError, "Decline does not take an approve field" if request.key?("approve")

      outcome = resolve_approval_request(request)
      return outcome if outcome

      proposal = @proposals.fetch(request["proposal_id"])
      resolving_on_failure(proposal) do
        accepted = accept_bound!(proposal, request)
        next accepted if accepted

        @proposals.delete(proposal["id"])
        tombstone!(proposal["id"], "declined")
        finish_parked_resolution!
        receipt(proposal, "refused", "not_applicable", "declined").merge("approval" => "spent")
      end
    end

    # Once a request has proved it holds the binding, no failure may leave the approval half alive:
    # the proposal is spent and the parked session resolves before the error is reported.
    def resolving_on_failure(proposal)
      yield
    rescue StandardError
      @proposals.delete(proposal["id"])
      tombstone!(proposal["id"], "failed") unless @consumed[proposal["id"]]
      finish_parked_resolution!
      raise
    end

    def refuse_rewrite_fields!(request)
      found = FORBIDDEN_APPROVE_FIELDS.select { |field| request.key?(field) }
      return if found.empty?

      raise ArgumentError, "Bound approval cannot rewrite #{found.join(", ")}; the stored action is fixed"
    end

    # Shared lookup for approve and decline. Returns an approval.v1 outcome for a request that does
    # not hold the binding (never spends), or nil when the stored proposal is live and the echoed
    # binding matches.
    def resolve_approval_request(request)
      id = request["proposal_id"]
      return approval_outcome("approval_lost", "unknown", false, request) if id.nil? || id.to_s.empty?
      return approval_outcome("approval_lost", "consumed", false, request) if @consumed[id]
      return approval_outcome("approval_lost", "unknown", false, request) unless @proposals.key?(id)

      proposal = @proposals[id]
      unless request["scope_id"] == proposal["scope_id"] && request["revision"] == proposal["revision"]
        return approval_outcome("approval_lost", "unknown", false, request)
      end
      # An ordinary previewed proposal in an interactive session is not this path's to spend.
      unless proposal.dig("policy", "consequential") && proposal.dig("policy", "permitted")
        raise ArgumentError, "Proposal is not awaiting bound approval"
      end

      nil
    end

    # Checks that run only for a request that holds the binding. Every outcome here is terminal.
    def accept_bound!(proposal, request)
      return lose_scope!(proposal, request) unless proposal["scope_id"] == @scope.id
      return lose_scope!(proposal, request) if @poisoned.is_a?(ScopeLost)

      ensure_usable!
      expire_bound(proposal, request)
    end

    def deliver_bound_approval(proposal)
      proposal["attempt_started"] = monotonic
      return spend_refused!(proposal, "provider_not_qualified") if proposal.dig("provider", "qualified") == false

      # Checked before any observation or durable marker: a locked screen keeps the same binding.
      locked = session_locked_outcome(proposal)
      return locked if locked

      fresh = observe_for_approval(proposal)
      return fresh if approval_result?(fresh) || fresh.key?("receipt")

      candidate = approval_revalidate(proposal, fresh)
      return candidate if approval_result?(candidate)

      receipt_value = dispatch_bound_candidate(proposal, fresh, candidate)
      finish_parked_resolution!
      { "receipt" => receipt_value, "evidence" => bound_approval_evidence }.compact
    end

    def approval_result?(value)
      value.is_a?(Hash) && value["schema"] == "wrangle.approval.v1"
    end

    def observe_for_approval(proposal)
      fresh_observation
    rescue ScopeLost
      lose_scope!(proposal, binding_fields(proposal))
    rescue DriverRefusal => e
      if scope_changed_refusal?(e)
        lose_scope!(proposal, binding_fields(proposal))
      elsif stale_ref_refusal?(e)
        spend_stale!(proposal, binding_fields(proposal))
      else
        refuse_before_marker!(proposal, e)
      end
    end

    # No durable marker exists yet, so nothing can have been sent: report not_delivered, spend the
    # approval, and resolve without poisoning.
    def refuse_before_marker!(proposal, error)
      @proposals.delete(proposal["id"])
      tombstone!(proposal["id"], "not_delivered")
      value = receipt(proposal, "not_delivered", "not_applicable", error.code)
      finish_parked_resolution!
      { "receipt" => value, "evidence" => bound_approval_evidence }.compact
    end

    def approval_revalidate(proposal, fresh)
      if fresh["revision"] != proposal["revision"]
        return spend_stale!(proposal, binding_fields(proposal), observation: fresh)
      end

      action_candidate = fresh["candidates"][proposal["number"] - 1]
      matched = same_candidate?(proposal["candidate"], action_candidate) &&
                action_candidate &&
                Array(action_candidate["operations"]).include?(proposal["operation"]) &&
                DesktopObservation.action_unambiguous?(
                  fresh["candidates"], action_candidate, proposal["operation"]
                )
      return spend_stale!(proposal, binding_fields(proposal), observation: fresh) unless matched

      action_candidate
    end

    def dispatch_bound_candidate(proposal, fresh, candidate)
      dispatch = begin_durable_dispatch(proposal)
      @proposals.delete(proposal["id"])
      tombstone!(proposal["id"], "delivered")
      delivery = @driver.execute(
        @scope, operation: proposal["operation"], ref: candidate["ref"], text: proposal["text"]
      )
      return finish_undelivered(proposal, dispatch, delivery) if
        %w[not_delivered refused].include?(delivery["dispatch"])

      finish_observed_delivery(proposal, fresh, dispatch, delivery)
    rescue DriverRefusal => e
      # Only a helper that states the action was not delivered may finish the marker. Any other
      # refusal after the marker leaves delivery unknown: poison and keep the marker unresolved.
      unknown_after_marker!(e) unless e.delivery == "not_delivered"

      @registry.finish_dispatch(dispatch)
      receipt(proposal, "not_delivered", "not_applicable", e.code, durable: true)
    rescue DeliveryUnknown => e
      @poisoned ||= e
      raise
    rescue StandardError => e
      unknown_after_marker!(e)
    end

    def unknown_after_marker!(cause)
      @poisoned ||= DeliveryUnknown.new("Desktop action delivery was interrupted after durable dispatch began")
      raise @poisoned, cause:
    end

    def session_locked_outcome(proposal)
      return nil unless driver_session_locked?

      approval_outcome(
        "session_locked", "session_locked", true,
        binding_fields(proposal), proposal_id: proposal["id"]
      )
    end

    def driver_session_locked?
      return false unless @driver.respond_to?(:doctor)

      report = @driver.doctor
      report.is_a?(Hash) && report["session_locked"] == true
    rescue DriverError
      false
    end

    def expire_bound(proposal, request)
      return nil unless monotonic - proposal["created_at"] > DesktopProposal::TTL

      @proposals.delete(proposal["id"])
      tombstone!(proposal["id"], "expired")
      finish_parked_resolution!
      approval_outcome("approval_expired", "expired", false, request, proposal_id: proposal["id"])
    end

    def spend_stale!(proposal, request, observation: nil)
      @observation = observation if observation
      @proposals.delete(proposal["id"])
      tombstone!(proposal["id"], "stale")
      # Stale target spends the approval and does not poison the session.
      finish_parked_resolution!
      approval_outcome("approval_lost", "stale_target", false, request, proposal_id: proposal["id"])
    end

    def lose_scope!(proposal, request)
      @proposals.delete(proposal["id"])
      tombstone!(proposal["id"], "lost_scope")
      @poisoned ||= ScopeLost.new("The attached window or process is no longer the one handed over")
      finish_parked_resolution!
      approval_outcome("approval_lost", "lost_scope", false, request, proposal_id: proposal["id"])
    end

    def spend_refused!(proposal, reason)
      @proposals.delete(proposal["id"])
      tombstone!(proposal["id"], reason)
      finish_parked_resolution!
      value = receipt(proposal, "refused", "not_applicable", reason).merge("approval" => "spent")
      { "receipt" => value }
    end

    def tombstone!(proposal_id, reason)
      @consumed[proposal_id] = reason
    end

    # Only a parked task session ends with its approval. An attached interactive session keeps its
    # lease and stays open. The application window is never closed either way (root_preserved).
    def finish_parked_resolution!
      return unless @parked_approval

      @parked_approval = false
      @approval_resolved = true
      shutdown unless @serving
    end

    def parked_deadline
      proposal = @proposals[@parked_proposal_id]
      return monotonic unless proposal

      proposal["created_at"] + DesktopProposal::TTL
    end

    def expire_parked_approval!
      proposal = @proposals.delete(@parked_proposal_id)
      tombstone!(@parked_proposal_id, "expired") if proposal
      @log&.record("approval", "proposal_id" => @parked_proposal_id, "status" => "approval_expired")
      @parked_approval = false
      @approval_resolved = true
    end

    def approval_outcome(status, reason, retryable, request, proposal_id: nil)
      {
        "schema" => "wrangle.approval.v1",
        "status" => status,
        "reason" => reason,
        "retryable" => retryable,
        "proposal_id" => proposal_id || request["proposal_id"],
        "scope_id" => request["scope_id"],
        "revision" => request["revision"]
      }.compact
    end

    def binding_fields(proposal)
      { "proposal_id" => proposal["id"], "scope_id" => proposal["scope_id"],
        "revision" => proposal["revision"] }
    end

    def stale_ref_refusal?(error)
      code = error.code.to_s
      code == "STALE_REF" || code.downcase == "stale_ref"
    end

    def scope_changed_refusal?(error)
      error.code.to_s == "scope_changed"
    end

    # Same bounds and literal redaction as task evidence. This is evidence, not a receipt.
    def bound_approval_evidence
      @task_text_values ||= []
      task_evidence("delivered")
    end

    def approval_binding(proposal)
      {
        "proposal_id" => proposal["id"] || proposal["proposal_id"],
        "scope_id" => proposal["scope_id"],
        "revision" => proposal["revision"],
        "ttl_seconds" => DesktopProposal::TTL,
        "session" => parked_session_name,
        # Tool-only: the exact string the driver will type (the stored proposal text, chosen from the
        # literals or DesktopDecider.quoted_spans). pending_action keeps only source and characters.
        "pending_text" => proposal["text"],
        "pending_summary" => pending_summary(proposal)
      }.compact
    end

    # Tool-only, on every consequential binding, so the person can see what they approve even when
    # the action itself types nothing. typed_text is the exact text this action would type; failing
    # that, the text this task most recently delivered by SET_TEXT in this window (what a Send would
    # send); otherwise nil. Exact strings only, never truncated or redacted; never logged.
    def pending_summary(proposal)
      candidate = proposal.fetch("candidate")
      {
        "app" => @scope.app, "operation" => proposal["operation"],
        "role" => candidate["role"], "label" => candidate["label"],
        "typed_text" => proposal["text"] || Array(@task_typed).last
      }
    end

    def parked_session_name
      return unless @socket_path

      File.basename(@socket_path, ".sock")
    end

    def park_approval_from_task!(result, proposal)
      @parked_approval = true
      @approval_resolved = false
      @parked_proposal_id = proposal["id"]
      result.merge("binding" => approval_binding(proposal))
    end
  end
end
