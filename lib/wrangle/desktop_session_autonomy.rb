# frozen_string_literal: true

require "json"
require "securerandom"

require_relative "desktop_autonomy"
require_relative "desktop_observation"

module Wrangle
  # Goal-driven preview and bounded continuation mixed into the persistent desktop session.
  # The proposal, receipt, and lifecycle paths stay together so authorization cannot drift.
  # rubocop:disable Metrics/ModuleLength
  module DesktopSessionAutonomy
    DEFAULT_BUDGET = 8
    MAX_BUDGET = 40
    TASK_MAX_BUDGET = 8
    TASK_MAX_DRILLS = 3
    TASK_EVIDENCE_ITEMS = 12
    TASK_EVIDENCE_BYTES = 4 * 1024

    # One natural request owns the complete bounded loop. Low-level capabilities stay internal:
    # every mutation still passes through preview, provider qualification, one-shot execution,
    # fresh-target validation, and independent effect verification.
    def autonomous_task(request)
      raise ConfigurationError, "A desktop task requires an explicit decision provider" unless @autonomy

      budget = Integer(request.fetch("steps", DEFAULT_BUDGET))
      unless budget.between?(1, TASK_MAX_BUDGET)
        raise ArgumentError, "Desktop task budget must be between 1 and #{TASK_MAX_BUDGET}"
      end

      @task_drills = 0
      @task_goal = request.fetch("goal")
      @task_text_values = Array(request["literals"]&.values) + quoted_task_spans(@task_goal)
      observe unless @observation
      state = { remaining: budget, history: [], actions: [] }
      @task_history = state.fetch(:history)
      loop do
        result = autonomous_task_step(request, state)
        return result if result
      end
    end

    def autonomous_preview(request)
      raise ConfigurationError, "Attach with an explicit decision provider first" unless @autonomy

      budget = Integer(request.fetch("steps", DEFAULT_BUDGET))
      unless budget.between?(1, MAX_BUDGET)
        raise ArgumentError, "Desktop run budget must be between 1 and #{MAX_BUDGET}"
      end

      observe unless @observation
      assessment = assess(request)
      choice = assessment.choice
      log_decision(choice)
      return @autonomy.compact(assessment) if choice.terminal? || assessment.paused

      proposal = preview("ref" => choice.number, "operation" => choice.operation, "text" => choice.text)
      run = start_run(request, budget)
      qualify_proposal(proposal, choice, run:)
      @autonomy.compact(assessment, proposal:).merge("run_id" => run.fetch("id"))
    end

    def continue_run(request)
      run = @runs[request["run_id"]]
      raise ArgumentError, "Unknown desktop run" unless run
      raise PolicyDenied, "Execute the current proposal before continuing" unless run["authorized"]
      raise PolicyDenied, "Execute the pending consequential proposal before continuing" if run["proposal_id"]

      receipts = []
      while run["remaining"].positive?
        result = continuation_step(run, receipts)
        return result if result
      end
      run_result(run, "budget_exhausted", receipts:)
    end

    def record_run_receipt(proposal, action_receipt)
      run = @runs[proposal["run_id"]]
      return action_receipt unless run

      can_continue = false
      if action_receipt["dispatch"] == "delivered"
        run["authorized"] = true
        run["remaining"] -= 1
        run["history"] << { "operation" => proposal["operation"], "effect" => action_receipt["effect"] }
        run["proposal_id"] = nil
        can_continue = run["remaining"].positive? && !action_receipt["terminal"]
        @runs.delete(run["id"]) unless can_continue
      elsif action_receipt["reason"] != "approval_required"
        run["proposal_id"] = nil
        @runs.delete(run["id"])
      end
      action_receipt.merge("run_id" => run["id"], "can_continue" => can_continue)
    end

    private

    def autonomous_task_step(request, state)
      assessment = assess(request.merge("history" => state[:history]), drill_limit: TASK_MAX_DRILLS)
      choice = assessment.choice
      log_decision(choice)
      return task_result("low_confidence", **state.slice(:remaining, :actions), assessment:) if assessment.paused
      return task_result(choice.operation.downcase, **state.slice(:remaining, :actions), assessment:) if
        choice.terminal?

      candidate = @observation.fetch("candidates").fetch(choice.number - 1)
      proposal = preview("ref" => choice.number, "operation" => choice.operation, "text" => choice.text)
      qualify_task_proposal(proposal, choice)
      pending = task_action(candidate, choice)
      halted = task_preflight_result(proposal, pending, assessment, state)
      return halted if halted

      task_receipt_result(proposal, pending, choice, assessment, state)
    end

    def task_preflight_result(proposal, pending, assessment, state)
      status = if proposal.dig("policy", "consequential")
                 "approval_required"
               elsif !@provider.mutation_qualified?
                 "provider_not_qualified"
               end
      task_result(status, **state.slice(:remaining, :actions), assessment:, pending:) if status
    end

    def task_receipt_result(proposal, pending, choice, assessment, state)
      action_receipt = execute("proposal_id" => proposal.fetch("proposal_id"))
      state[:actions] << pending.merge(action_receipt.slice("dispatch", "effect", "reason", "terminal"))
      dispatch = action_receipt.fetch("dispatch")
      return task_result(dispatch, **state.slice(:remaining, :actions), assessment:) unless dispatch == "delivered"

      state[:remaining] -= 1
      state[:history] << { "operation" => choice.operation, "effect" => action_receipt["effect"] }
      return task_result("terminal", **state.slice(:remaining, :actions), assessment:) if action_receipt["terminal"]

      task_result("budget_exhausted", **state.slice(:remaining, :actions), assessment:) if
        state[:remaining].zero?
    end

    def assess(request, drill_limit: nil)
      @autonomy.assess(
        goal: request["goal"], literals: request["literals"] || {}, observation: @observation,
        history: Array(request["history"]), min_confidence: request.fetch("min_confidence", 0.5)
      ) do |ref|
        if drill_limit && @task_drills >= drill_limit
          raise PartialObservation, "Desktop task exceeded the progressive DRILL budget"
        end

        @task_drills += 1 if drill_limit
        drill("ref" => ref) && @observation
      end
    end

    def qualify_task_proposal(proposal, choice)
      qualified = @provider.mutation_qualified?
      stored = @proposals.fetch(proposal.fetch("proposal_id"))
      stored["provider"] = { "name" => choice.provider, "model" => choice.model, "qualified" => qualified }
      proposal["policy"] = proposal.fetch("policy").merge("provider_qualified" => qualified)
    end

    def task_result(status, remaining:, actions:, assessment:, pending: nil)
      result = {
        "schema" => "wrangle.task.v1", "status" => status, "app" => @scope.app,
        "actions_taken" => @actions, "remaining" => remaining, "root_preserved" => true,
        "message" => task_message(status), "decision" => task_decision(assessment),
        "pending_action" => pending, "actions" => actions, "evidence" => task_evidence(status)
      }.compact
      @log&.record(
        "task", "scope_id" => @scope.id, "status" => status, "actions_taken" => @actions,
                "remaining" => remaining
      )
      result
    end

    def task_decision(assessment)
      choice = assessment.choice
      { "operation" => choice.operation, "confidence" => choice.confidence,
        "provider" => choice.provider, "model" => choice.model }
    end

    def task_action(candidate, choice)
      { "operation" => choice.operation, "role" => candidate["role"], "label" => candidate["label"],
        "text" => choice.text && { "source" => choice.text_source, "characters" => choice.text.length } }.compact
    end

    def task_evidence(status)
      observation = @observation
      return unless observation

      all = DesktopObservation.evidence_items(observation).map { |item| sanitize_evidence(item) }
      selected, selection = select_task_evidence(status, observation, all)
      selected.pop while selected.length > 1 && JSON.generate(selected).bytesize > TASK_EVIDENCE_BYTES
      {
        "complete" => observation["complete"], "items" => selected,
        "total" => all.length, "omitted" => all.length - selected.length,
        "explicit_truncation" => all.length > selected.length, "selection" => selection
      }
    rescue ProviderError
      fallback_task_evidence(observation, all, "provider_failed")
    end

    def select_task_evidence(status, observation, all)
      if status == "done" && all.length > TASK_EVIDENCE_ITEMS
        selected = @autonomy.evidence(
          goal: @task_goal, observation:, history: @task_history, limit: 3
        ).map { |candidate| sanitize_evidence(candidate) }
        [selected, "provider"]
      else
        [sample_evidence(all), "bounded"]
      end
    end

    def fallback_task_evidence(observation, all, selection)
      selected = sample_evidence(all)
      selected.pop while selected.length > 1 && JSON.generate(selected).bytesize > TASK_EVIDENCE_BYTES
      {
        "complete" => observation["complete"], "items" => selected,
        "total" => all.length, "omitted" => all.length - selected.length,
        "explicit_truncation" => all.length > selected.length, "selection" => selection
      }
    end

    def sample_evidence(all)
      return all if all.length <= TASK_EVIDENCE_ITEMS

      half = TASK_EVIDENCE_ITEMS / 2
      all.first(half) + all.last(half)
    end

    def sanitize_evidence(candidate)
      candidate.slice("role", "label", "value", "states").transform_values do |value|
        next value unless value.is_a?(String)

        redacted = @task_text_values.reduce(value) do |text, literal|
          literal.empty? ? text : text.gsub(literal, "[typed text omitted]")
        end
        redacted.length > 500 ? "#{redacted[0, 500]}…" : redacted
      end
    end

    def quoted_task_spans(goal)
      goal.scan(/"([^"]+)"|'([^']+)'/).map { |double, single| double || single }.uniq
    end

    def task_message(status)
      {
        "done" => "The requested result is visible in the application.",
        "blocked" => "No observed safe action can progress the request.",
        "handoff" => "The request needs a person or exact missing input.",
        "low_confidence" => "Wrangle paused because the next action was uncertain.",
        "approval_required" => "A consequential action requires separate approval; nothing was sent.",
        "provider_not_qualified" => "The decision provider may inspect but is not qualified to change the app.",
        "not_delivered" => "The app did not receive the proposed action.",
        "refused" => "Wrangle refused the proposed action.",
        "delivery_unknown" => "The action may or may not have happened and was not retried.",
        "terminal" => "Wrangle stopped after a terminal verification failure.",
        "budget_exhausted" => "Wrangle stopped at the task action limit."
      }.fetch(status, "Wrangle stopped without claiming success.")
    end

    def continuation_step(run, receipts)
      assessment = assess(run)
      choice = assessment.choice
      log_decision(choice)
      if assessment.paused || choice.terminal?
        status = assessment.paused ? "low_confidence" : choice.operation.downcase
        return run_result(run, status, receipts:, assessment:)
      end

      proposal = preview("ref" => choice.number, "operation" => choice.operation, "text" => choice.text)
      qualify_proposal(proposal, choice, run:)
      if proposal.dig("policy", "consequential")
        return run_result(run, "approval_required", receipts:, assessment:, proposal:)
      end
      unless @provider.mutation_qualified?
        return run_result(run, "provider_not_qualified", receipts:, assessment:, proposal:)
      end

      action_receipt = execute("proposal_id" => proposal["proposal_id"])
      receipts << action_receipt
      return run_result(run, "paused", receipts:) unless action_receipt["dispatch"] == "delivered"
      return run_result(run, "terminal", receipts:) if action_receipt["terminal"]

      nil
    end

    def start_run(request, budget)
      run = { "id" => SecureRandom.hex(12), "goal" => request["goal"], "literals" => request["literals"] || {},
              "history" => [], "min_confidence" => request.fetch("min_confidence", 0.5),
              "remaining" => budget, "authorized" => false, "proposal_id" => nil }
      @runs[run["id"]] = run
      run
    end

    def qualify_proposal(proposal, choice, run:)
      qualified = @provider.mutation_qualified?
      stored = @proposals.fetch(proposal["proposal_id"])
      stored["provider"] = { "name" => choice.provider, "model" => choice.model, "qualified" => qualified }
      stored["run_id"] = run["id"]
      run["proposal_id"] = proposal["proposal_id"]
      proposal["policy"] = proposal["policy"].merge("provider_qualified" => qualified)
    end

    def log_decision(choice)
      @log&.record(
        "decision", "scope_id" => @scope.id, "revision" => @observation["revision"],
                    "operation" => choice.operation, "confidence" => choice.confidence,
                    "latency_ms" => choice.latency_ms, "provider" => choice.provider, "model" => choice.model
      )
    end

    def run_result(run, status, receipts:, assessment: nil, proposal: nil)
      @runs.delete(run["id"]) unless status == "approval_required"
      {
        "schema" => "wrangle.run.v1", "run_id" => run["id"], "status" => status,
        "remaining" => run["remaining"], "decision" => assessment && @autonomy.compact(assessment),
        "proposal" => proposal, "receipts" => receipts
      }.compact
    end
  end
  # rubocop:enable Metrics/ModuleLength
end
