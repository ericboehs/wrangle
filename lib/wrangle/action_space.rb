# frozen_string_literal: true

module Wrangle
  # Collapses an observation's actions into the shape Jev is asked about.
  #
  # A page yields several actions against the same node — a combobox can be typed into and opened —
  # so they are folded into one element carrying the operations it supports. Fewer, richer rows beat
  # many thin ones: Jev loses accuracy as the state fills with detail, and a list with one row per
  # action repeats the same label three times.
  #
  # Ported from browser-use/jev-ultrafast (MIT). See LICENSE.txt.
  class ActionSpace
    OPERATIONS = { "click" => "CLICK", "fill" => "TYPE_TEXT", "select" => "SELECT" }.freeze
    FLAGS = %w[role checked selected expanded].freeze

    attr_reader :elements, :targets, :controls

    def initialize(actions)
      @elements = []
      @indices = {}
      @targets = {}
      @controls = {}
      actions.each { |action| absorb(action) }
    end

    # Waiting and scrolling are not aimed at an element, so they are offered as operations in their
    # own right. That is what lets the model say "this page is still loading" instead of the harness
    # sleeping a fixed interval on every single step.
    def absorb(action)
      operation = OPERATIONS[action["kind"]]
      return @controls[action["id"].upcase] = action unless operation

      index = index_for(action)
      element = @elements[index.to_i - 1]
      element["operations"] << operation unless element["operations"].include?(operation)
      register(operation, index, element, action)
    end

    def index_for(action)
      node = action["node"]
      return @indices[node] if @indices.key?(node)

      index = (@elements.length + 1).to_s
      @indices[node] = index
      element = { "index" => index, "label" => action["label"].to_s.split(" → ").first, "operations" => [] }
      FLAGS.each { |key| element[key] = action[key] if action.key?(key) }
      element["value"] = action["kind"] == "select" ? action["current_value"].to_s : action["value"]
      element["options"] = [] if action["kind"] == "select"
      @elements << element
      index
    end

    # A select names one option per target, so choosing a target is choosing a value that was
    # observed on the page rather than one the model composed.
    def register(operation, index, element, action)
      group = @targets[operation] ||= {}
      target = index
      if action["kind"] == "select"
        target = "#{index}:#{element["options"].length + 1}"
        element["options"] << { "index" => target, "label" => action["label"], "value" => action["value"] }
      end
      group[target] = action
    end

    def empty? = @targets.empty? && @controls.empty?
  end
end
