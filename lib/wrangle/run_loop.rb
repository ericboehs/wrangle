# frozen_string_literal: true

require_relative "errors"

module Wrangle
  # Runs a goal, or a plan of goals, to a stopping point.
  #
  # This is the only part of Wrangle that acts without being told to, so it is all policy: when a
  # decision may be executed, when a page deserves another look, and when the run has to hand back.
  # It never touches Safari itself — the session it is given owns that, and owns the page — which
  # keeps "what may happen" separate from "how it happens".
  #
  # The rules here were each written after a live page broke the version without them, and the
  # comments say which, because the reason is the only thing that makes them worth keeping.
  class RunLoop
    # Acting on a 5%-confidence target is how an early build typed the origin into Google's
    # multi-city field. Below the floor the run stops and says what it was torn between.
    DEFAULT_CONFIDENCE = 0.5
    # Settling starts impatient: a long poll on every step is what makes a run feel like it is
    # stalling, and a page that streams content in never goes still anyway.
    STEADY_BUDGET = 0.2
    STEADY_CEILING = 1.2
    MAX_MISSES = 4
    # A page half-rendered when the model looked reads as ambiguity. A second decision costs ~350ms
    # and a handoff to the calling agent costs a full model turn, measured at 5-6s.
    SOFT_SETTLE = 0.6
    MAX_SOFT = 1
    SPIN_ALLOWANCE = 3
    RECONSIDER = %i[unsure soft_done absent].freeze
    DEFAULT_LEG_STEPS = 8
    # Acting wrongly costs one action, which the next step can usually undo. Declaring BLOCKED throws
    # away every remaining leg, and no later step can recover it.
    BLOCKED_FLOOR = 0.6
    BLOCKED_RELOOKS = 3
    # Settling a churning page and waiting for a control to arrive are different kinds of patience.
    # Amazon's filter sidebar has taken over two seconds after its results were already interactive.
    BLOCKED_CEILING = 2.5
    # A confident disagreement from the verification head outweighs the claim; an unsure one is noise.
    VERIFY_FLOOR = 0.6
    # A claim is put back to the page this many times before the loop stops arguing with it. A leg
    # that has acted is only arguing about whether its own work shows, so one more look settles it; a
    # leg that has done nothing is the premature-DONE case, and that one is worth pressing.
    CLAIM_LOOKS = { acted: 2, idle: 3 }.freeze

    def initialize(session, request, expect)
      @session = session
      @request = request
      @expect = expect
    end

    # One CLI call, several sub-goals. Each leg runs to its own DONE and the next begins, so the
    # caller is not paid a full model turn for every handoff — on a form that was ten round trips to
    # the calling agent, which dwarfed the decisions themselves. A leg that does not reach DONE ends
    # the plan: the later legs assume the earlier ones happened, so guessing past a failure is how a
    # run types a date into a passenger field.
    def run(plan)
      budget = (@request["steps"] || 20).to_i
      leg_cap = (@request["leg_steps"] || DEFAULT_LEG_STEPS).to_i
      steps = []
      plan.each_with_index do |goal, index|
        remaining = budget - steps.count { |step| step["operation"] != "GOAL" }
        break if remaining <= 0

        steps << goal_step(goal, index) if plan.size > 1
        leg = leg(@request.merge("goal" => goal), [remaining, leg_cap].min)
        steps.concat(leg)
        break unless leg.last&.fetch("operation", nil) == "DONE"
      end
      steps
    end

    private

    def goal_step(goal, index) = { "operation" => "GOAL", "action" => goal, "confidence" => 0.0, "index" => index + 1 }

    # The budget counts work done, not attempts made. A stale retry, a second look at a half-rendered
    # page, or a claim that did not check out is overhead, and charging it to the leg means a form
    # that churns a little runs out of allowance before it finishes — while a separate spin cap still
    # stops a loop that is making no progress at all.
    def leg(request, budget)
      steps = []
      tally = { missed: 0, soft: 0, done: 0, claims: 0 }
      spins = 0
      while tally[:done] < budget && spins < budget * SPIN_ALLOWANCE
        spins += 1
        outcome = attempt(request, steps, tally)
        break if outcome == :stale && tally[:missed] >= MAX_MISSES
        next if outcome == :stale

        look = reconsider(outcome, steps, tally)
        next if look == :again
        break if look == :spent

        # A disputed DONE is not work and does not spend the budget. The leg carries on and looks
        # again, which is what it would have done had it never claimed to be finished — but not
        # instantly: "the page has not got there yet" is the commonest true reason for a dispute, and
        # asking again in the same breath gets the same answer. Amazon's results were mid-load for
        # both claims, and a search that had plainly worked was handed back.
        if outcome == :unproven
          @session.steady(patience(:absent, tally[:claims] - 1))
          next
        end
        break if outcome == :stop

        tally.merge!(soft: 0, missed: 0, done: tally[:done] + 1)
        break if @expect && @session.page["text"].match?(@expect)
        break if @session.stalled?
      end
      steps
    end

    # Spend the cheap look before the expensive handoff, then stop asking.
    def reconsider(outcome, steps, tally)
      return nil unless RECONSIDER.include?(outcome)
      return :spent if tally[:soft] >= (outcome == :absent ? BLOCKED_RELOOKS : MAX_SOFT)

      waited = patience(outcome, tally[:soft])
      tally[:soft] += 1
      steps.push(looked_again(steps.pop, tally[:soft], waited))
      @session.steady(waited)
      :again
    end

    # A stale page means the decision was made about a page that no longer exists. The freshness
    # check fires before any input, so nothing was delivered and deciding again is safe. This is the
    # one retry Wrangle allows itself, and only because no mutation happened.
    def attempt(request, steps, tally)
      began = now
      # When the page proves it is churning faster than a decision can be made, back off instead of
      # spinning — an animating menu will invalidate the target forever at a fixed retry rate.
      @session.steady(backoff(request.fetch("steady", STEADY_BUDGET).to_f, tally[:missed]))
      step = @session.decide(request)
      steps << step.except("choice")
      advance(step, request, steps.last, began, tally)
    rescue StalePage
      tally[:missed] += 1
      steps << missed_step(tally[:missed], began)
      :stale
    end

    def advance(step, request, record, began, tally)
      choice = step.fetch("choice")
      return stopping(choice, request, record, tally) if choice.stop?
      return :unsure if unsure?(choice, request, record)

      text, wanted = text_for(choice, request)
      if wanted
        record.merge!("operation" => "HANDOFF", "action" => wanted)
        return :stop
      end
      record.merge!(@session.perform(choice, text).merge("step_ms" => ((now - began) * 1000).round))
      :go
    end

    # DONE and BLOCKED are not symmetric. Inside a plan an uncertain DONE is cheap to be wrong about —
    # the next leg simply does the work that was not done — while an uncertain BLOCKED abandons every
    # remaining leg. So look again at both, then let DONE through and make BLOCKED earn a handoff.
    def stopping(choice, request, record, tally)
      return :absent if unconfirmed_blocked?(choice, request, record, tally)

      disputed = disputed_done(choice, request, record, tally)
      return disputed if disputed
      return :stop unless weak?(choice, request)
      return :absent if choice.operation == "BLOCKED" && unsure?(choice, request, record)

      :soft_done
    end

    # DONE is the model reporting on its own work, chosen from the same look that proposed the
    # actions, and it is optimistic: an Amazon plan reported success with the filter it had been
    # asked for never applied. The verification head asked alongside it has no action to gain by
    # saying yes, so a confident disagreement is worth more than the claim.
    #
    # But it is worth more, not final, and the two ways of being wrong do not cost the same. The
    # verifier reads one snapshot; the actor knows what it did. A leg that applied an Amazon filter
    # was disputed at 80% five runs in a row, because the only proof on the page was one link
    # offering to remove the filter, among a hundred other elements — and handing back there throws
    # away every remaining leg to win an argument the page cannot settle.
    #
    # So the dispute is decisive only against a leg that has not done anything, which is the case it
    # was built for. A leg that acted is taken at its word once it has looked again, and the doubt is
    # written into the transcript for whoever reads it.
    def disputed_done(choice, request, record, tally)
      return nil unless choice.operation == "DONE" && choice.disputed?(VERIFY_FLOOR)

      tally[:claims] += 1
      idle = tally[:done].zero?
      said = "the page does not show #{request["goal"].to_s.inspect} (#{pct(choice.met_confidence)} sure)"
      return unproven(record, choice, said) if tally[:claims] < CLAIM_LOOKS[idle ? :idle : :acted]
      return handoff(record, choice, said, tally) if idle

      record["action"] = "Done, but #{said}; taking the work at its word"
      nil
    end

    def unproven(record, choice, said)
      record.merge!("operation" => "UNPROVEN", "confidence" => choice.met_confidence,
                    "action" => "Said done, but #{said}; carrying on")
      :unproven
    end

    def handoff(record, choice, said, tally)
      record.merge!("operation" => "HANDOFF", "confidence" => choice.met_confidence,
                    "action" => "Said done #{tally[:claims]} times without doing anything, " \
                                "but #{said}; check it yourself")
      :stop
    end

    # A leg begins the instant the one before it ends, and the action that ended it may have started
    # a navigation. So the first decisions of a leg are looking at the previous page as often as not,
    # and "the control is not here" is exactly what a half-loaded document looks like.
    #
    # Confidence cannot gate this. Looking again at a page whose sidebar still has not arrived makes
    # the model surer of the absence, not less — 43% then 76%, both wrong. What makes a BLOCKED cheap
    # to disbelieve is that the leg has not done anything yet: there is nothing to undo, and nothing
    # to lose but the wait.
    def fresh_leg?(tally) = tally[:done].zero? && tally[:soft].to_i < BLOCKED_RELOOKS

    def unconfirmed_blocked?(choice, request, record, tally)
      return false unless choice.operation == "BLOCKED" && fresh_leg?(tally)

      unsure?(choice, request, record, force: true)
    end

    def unsure?(choice, request, record, force: false)
      return false unless force || weak?(choice, request)

      weakest = confidence(choice)
      reason = if force && !weak?(choice, request)
                 "#{choice.label.inspect} on a leg that has not acted yet (#{pct(weakest)} sure)"
               else
                 "Not sure enough to act (#{pct(weakest)} on #{choice.label.inspect})"
               end
      record.merge!("operation" => "HANDOFF", "confidence" => weakest,
                    "action" => "#{reason}; look at the page and choose")
      true
    end

    # Jev chooses; it never writes. The value comes from the caller, and when the caller has not
    # supplied one the run stops and asks. The agent driving Wrangle is already a language model, so
    # the "small model that types" is whoever is reading this output — no second key, no extra hop.
    def text_for(choice, request)
      return [nil, nil] unless choice.action["kind"] == "fill"

      label = choice.label.downcase
      _, literal = (request["literals"] || {}).find { |key, _| label.include?(key.to_s.downcase) }
      return [literal, nil] if literal

      [nil, "needs text for #{choice.label.inspect}; re-run with --literal #{label.split(/[^a-z]/).first}=VALUE"]
    end

    # A second look is not free and it is not nothing: it explains both the pause and why the run
    # ended up where it did, so it belongs in the transcript rather than being quietly discarded.
    def looked_again(step, look, waited)
      { "operation" => "RELOOK", "confidence" => step["confidence"],
        "action" => "#{step["operation"] == "HANDOFF" ? step["action"][/\A[^;]+/] : "Not sure yet"}; " \
                    "waited #{(waited * 1000).round}ms and looked again (#{look})" }
    end

    def missed_step(missed, began)
      @session.observe!
      { "operation" => "RESTALE", "confidence" => 0.0, "step_ms" => ((now - began) * 1000).round,
        "action" => "The page moved while deciding; looked again (#{missed})" }
    end

    def floor_for(choice, request)
      base = (request["min_confidence"] || DEFAULT_CONFIDENCE).to_f
      choice.operation == "BLOCKED" ? [base, BLOCKED_FLOOR].max : base
    end

    def weak?(choice, request) = confidence(choice) < floor_for(choice, request)
    def confidence(choice) = [choice.confidence, choice.target_confidence].compact.min.to_f
    def backoff(base, missed) = missed.zero? ? base : [base * (2**missed), STEADY_CEILING].min
    def patience(outcome, soft) = [SOFT_SETTLE * (2**soft), outcome == :absent ? BLOCKED_CEILING : STEADY_CEILING].min
    def pct(value) = "#{(value.to_f * 100).round}%"
    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
