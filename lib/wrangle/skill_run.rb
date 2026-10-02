# frozen_string_literal: true

require_relative "skill_chooser"
require_relative "skill_teacher"

module Wrangle
  # Turns a request into the plan the existing loop already knows how to run.
  #
  # An explicit plan wins, because the caller already supplied the procedure. A miss leaves the
  # original goal alone. Teaching happens only after the loop reports success, and a save failure
  # is recorded rather than thrown away with the work that just succeeded.
  class SkillRun
    Prepared = Data.define(:request, :plan, :resolution, :host, :app, :supplied_plan)

    def self.store_for(request)
      dir = request["skills_dir"]
      dir ? SkillStore.new(dir:) : SkillStore.default
    end

    def self.skip?(request, store)
      request["no_skill"] || present(request["plan"]).any? || store.none?
    end

    def self.prepare(request, store:, app:, host:, asker:)
      supplied = present(request["plan"])
      return skipped(request, app, supplied, skip_source(request, supplied)) if skip?(request, store)

      resolution = SkillChooser.new(store:, asker:).choose(app:, host:, goal: request.fetch("goal"))
      apply(request, resolution, app, host, supplied)
    end

    def self.complete(summary, prepared, store:, page:, teach:, goal: nil)
      body = summary.merge("skill" => prepared.resolution.to_h)
      return body unless teach && succeeded?(summary)

      body.merge("taught" => teach_now(prepared, goal || summary["goal"], store, page))
    end

    def self.succeeded?(summary)
      return summary["status"] == "done" if summary.key?("status")

      summary["stopped"] == "DONE" && summary["proven"] != false
    end

    def self.present(values)
      Array(values).filter_map { |value| value.to_s.empty? ? nil : value.to_s }
    end

    def self.skip_source(request, supplied)
      return "disabled" if request["no_skill"]
      return "explicit_plan" if supplied.any?

      "none"
    end

    def self.skipped(request, app, supplied, source)
      plan = supplied.empty? ? [request.fetch("goal")] : supplied
      Prepared.new(
        request:, plan:, resolution: SkillChooser::Resolution.skipped(source),
        host: nil, app:, supplied_plan: supplied
      )
    end

    def self.apply(request, resolution, app, host, supplied)
      goal = request.fetch("goal")
      plan = resolution.applied? ? resolution.skill.plan_for(goal) : [goal]
      working = resolution.applied? ? request.merge("plan" => plan) : request
      Prepared.new(request: working, plan:, resolution:, host:, app:, supplied_plan: supplied)
    end

    def self.teach_now(prepared, goal, store, page)
      SkillTeacher.new(store).teach(
        app: prepared.app, host: prepared.host || UiSkill.host_of(page && page["url"]), goal:,
        legs: legs_for(prepared, goal), stop: prepared.resolution.skill&.stop,
        existing_id: prepared.resolution.skill&.id
      )
    rescue SkillInvalid, SystemCallError => e
      { "saved" => false, "error" => e.message }
    end

    def self.legs_for(prepared, goal)
      return prepared.supplied_plan if prepared.supplied_plan.any?
      return prepared.resolution.skill.legs if prepared.resolution.skill

      [goal.to_s]
    end
  end
end
