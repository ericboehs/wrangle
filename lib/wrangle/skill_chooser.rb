# frozen_string_literal: true

require_relative "decision_provider"
require_relative "skill_store"
require_relative "ui_skill"

module Wrangle
  # Picks a stored procedure, or none. The model may choose only an id that the index already
  # returned. A miss, a weak match, or a malformed answer explores; it never invents a skill.
  class SkillChooser
    MAX_OFFERED = 7
    FLOOR = 0.5
    RULES = <<~TEXT
      Choose the stored procedure that best matches the user's goal, or none.
      A skill is only an ordered plan of sub-goals. It is not evidence of live availability, prices, or state.
      Prefer none when no candidate clearly fits. Never invent a skill id. Choose only an offered id.
    TEXT
    NONE_LABEL = "Explore without a stored procedure. Prefer this when no candidate clearly fits. " \
                 "A skill is not live availability or prices."

    Resolution = Data.define(:skill, :source, :confidence, :candidate_ids, :applied) do
      def self.selected(skill, source:, confidence:, candidate_ids:)
        new(skill:, source:, confidence:, candidate_ids:, applied: true)
      end

      def self.skipped(source, candidate_ids: [])
        new(skill: nil, source:, confidence: 0.0, candidate_ids:, applied: false)
      end

      def applied? = applied

      def to_h
        body = { "applied" => applied, "source" => source }
        if skill
          body["id"] = skill.id
          body["version"] = skill.version
          body["confidence"] = confidence
        elsif candidate_ids.any?
          body["candidates"] = candidate_ids
        end
        body
      end
    end

    def initialize(store:, asker: nil)
      @store = store
      @asker = asker
    end

    def choose(app:, host:, goal:)
      strong, weak = partition(app, host, goal)
      return Resolution.skipped("weak", candidate_ids: weak.map(&:id)) if strong.empty? && weak.any?
      return Resolution.skipped("none") if strong.empty?
      return clear(strong.fetch(0)) if strong.one?

      ask(strong, app, host, goal)
    end

    def self.ask_jev(jev, state, criteria, instructions)
      response = jev.ask(
        state:,
        questions: {
          "skill" => {
            "type" => "choice", "criteria" => criteria,
            "instructions" => { "goal" => state["goal"], "rules" => instructions }
          }
        }
      )
      response.dig("answers", "skill") if response.is_a?(Hash)
    end

    private

    def partition(app, host, goal)
      surface = @store.load.select { |skill| skill.surface_match?(app:, host:) }
      pool = exact_pool(surface, goal)
      eligible = pool.reject { |skill| skill.weak_for?(goal) }
      [rank(eligible, goal), pool - eligible]
    end

    def exact_pool(surface, goal)
      fingerprint = UiSkill.fingerprint(goal)
      exact = surface.select { |skill| skill.fingerprint == fingerprint }
      exact.empty? ? surface : exact
    end

    def rank(skills, goal)
      skills.sort_by { |skill| [-skill.overlap(goal), skill.id] }.first(MAX_OFFERED)
    end

    def clear(skill)
      Resolution.selected(skill, source: "clear", confidence: 1.0, candidate_ids: [skill.id])
    end

    def ask(strong, app, host, goal)
      criteria = criteria_for(strong)
      answer = consult(skill_state(app, host, goal), criteria, RULES)
      return Resolution.skipped("unavailable", candidate_ids: strong.map(&:id)) if answer.nil? || answer == :unavailable

      accept(answer, criteria, strong)
    end

    def criteria_for(strong)
      offered = strong.to_h { |skill| [skill.id, skill.choice_label] }
      offered["none"] = NONE_LABEL
      offered
    end

    def skill_state(app, host, goal) = { "goal" => goal, "app" => app, "host" => host }

    def consult(state, criteria, instructions)
      return nil unless @asker

      if provider?(@asker)
        decision_answer(@asker.choose(state:, name: "skill", criteria:, instructions:))
      else
        @asker.call(state, criteria, instructions)
      end
    rescue JevError, ProviderError, ConfigurationError
      :unavailable
    end

    def provider?(asker) = !asker.is_a?(Proc) && asker.respond_to?(:choose)

    def decision_answer(decision)
      {
        "choice" => decision.choice, "confidence" => decision.confidence,
        "probabilities" => decision.probabilities
      }
    end

    def accept(answer, criteria, strong)
      checked = ChoiceCheck.normalize(answer, criteria.keys)
      ids = criteria.keys - ["none"]
      return Resolution.skipped("rejected", candidate_ids: ids) unless checked
      return Resolution.skipped("declined", candidate_ids: ids) if checked[:choice] == "none"
      return Resolution.skipped("weak_choice", candidate_ids: [checked[:choice]]) if checked[:confidence] < FLOOR

      skill = strong.find { |item| item.id == checked[:choice] }
      Resolution.selected(skill, source: "choice", confidence: checked[:confidence], candidate_ids: ids)
    end
  end

  # The same distribution rules the action decider uses. A skill choice that does not name its own
  # probability as the largest offered one is not a choice.
  module ChoiceCheck
    module_function

    def normalize(answer, offered)
      return nil unless answer.is_a?(Hash)

      probabilities = answer["probabilities"]
      choice = answer["choice"]
      confidence = answer["confidence"]
      return nil unless sound?(probabilities, confidence, choice, offered)

      { choice:, confidence: confidence.to_f }
    end

    def sound?(probabilities, confidence, choice, offered)
      return false unless probabilities.is_a?(Hash) && offered.include?(choice)
      return false unless probabilities.keys.sort == offered.sort
      return false unless unit?(probabilities.values + [confidence])
      return false unless (probabilities.values.sum - 1).abs < 0.02

      probabilities[choice] >= probabilities.values.max - 1e-6
    end

    def unit?(numbers)
      numbers.all? { |number| number.is_a?(Numeric) && number.finite? && number.between?(0, 1) }
    end
  end
end
