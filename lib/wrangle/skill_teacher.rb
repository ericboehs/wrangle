# frozen_string_literal: true

require_relative "skill_store"
require_relative "ui_skill"

module Wrangle
  # Saves the procedure that just worked, not the page it worked on.
  #
  # Legs are clipped and stripped of the binding suffix the runner adds, so teaching a run cannot
  # nest "Overall goal" forever or copy prices, titles, or typed secrets out of the observation.
  class SkillTeacher
    SUMMARY = "Taught procedure. Recheck live UI state; do not reuse remembered availability or prices."

    def initialize(store) = @store = store

    def teach(app:, host:, goal:, legs:, stop: nil, existing_id: nil)
      id = existing_id || UiSkill.derive_id(app:, host:, goal:)
      previous = @store.find(id)
      skill = UiSkill.build(
        id:, version: previous ? previous.version + 1 : 1,
        title: UiSkill.clip(goal, UiSkill::MAX_TITLE), summary: SUMMARY,
        apps: apps_for(app, previous), hosts: hosts_for(host, previous),
        goal_terms: UiSkill.tokens(goal).first(UiSkill::MAX_TERMS), legs: thin_legs(legs, goal),
        stop: stop.to_s.empty? ? UiSkill::DEFAULT_STOP : UiSkill.clip(stop, UiSkill::MAX_STOP),
        source: "teach", taught_at: Time.now.utc.iso8601, fingerprint: UiSkill.fingerprint(goal)
      )
      path = @store.save(skill)
      { "saved" => true, "id" => skill.id, "version" => skill.version, "path" => path }
    end

    private

    def apps_for(app, previous)
      return [app] unless app.to_s.strip.empty?

      previous&.apps || []
    end

    def hosts_for(host, previous)
      normalized = UiSkill.normalize_host(host)
      return [normalized] unless normalized.empty?

      previous&.hosts || []
    end

    def thin_legs(legs, goal)
      cleaned = Array(legs).filter_map do |leg|
        text = strip(leg)
        text unless text.empty?
      end
      cleaned = [UiSkill.clip(goal, UiSkill::MAX_LEG)] if cleaned.empty?
      raise SkillInvalid, "A taught skill needs a goal" if cleaned.all?(&:empty?)

      cleaned.first(UiSkill::MAX_LEGS).map { |leg| UiSkill.clip(leg, UiSkill::MAX_LEG) }
    end

    def strip(leg)
      text = leg.to_s.gsub(/[\r\n\t]+/, " ")
      text.sub(/\s+Overall goal:.*\z/, "").sub(/\s+Stop only when:.*\z/, "").strip
    end
  end
end
