# frozen_string_literal: true

# A stand-in for the TypeSafe endpoint that answers from a script instead of a network call.
#
# The point is not to fake a model but to fake a *well-formed* model: every answer it returns is
# built to satisfy Decider#validate, so a test that passes is a test where the real contract held —
# the distribution covers exactly the offered options, sums to one, and the named choice is its
# argmax. A script entry that cannot be expressed that way raises here rather than quietly producing
# an answer the real decider would reject.
class ScriptedJev
  # One scripted decision. `target` is matched against the offered action labels by substring, so a
  # test can say "Find stays" without knowing the generated action id.
  # `met` answers the verification head that rides along with every request: true or false for a
  # definite reading of the page, and a `met_confidence` the loop weighs against its floor. Left nil,
  # the head is answered YES at full confidence, which disputes nothing.
  Turn = Struct.new(:operation, :target, :confidence, :target_confidence, :met, :met_confidence,
                    keyword_init: true)

  attr_reader :asked

  # `thinks_for` makes the answer take time. The real one takes about 350ms, and the page is watched
  # while it does; a fixture that answers instantly leaves that window closed and nothing to test.
  def initialize(turns, thinks_for: 0)
    @turns = turns.map { |turn| turn.is_a?(Turn) ? turn : Turn.new(**turn) }
    @thinks_for = thinks_for
    @asked = []
  end

  def ask(state:, questions:)
    turn = @turns.shift or raise "ScriptedJev ran out of script after #{@asked.length} calls"

    sleep @thinks_for if @thinks_for.positive?
    @asked << { goal: state.dig("instructions", "goal") || questions.dig("operation", "instructions", "goal"),
                operation: turn.operation }

    answers = { "operation" => answer(questions.fetch("operation"), turn.operation, turn.confidence) }
    if questions.key?("goal_met")
      met = turn.met.nil? || turn.met
      answers["goal_met"] = answer(questions.fetch("goal_met"), met ? "YES" : "NO", turn.met_confidence || 0.9)
    end
    head = "#{turn.operation.downcase}_target"
    if questions.key?(head)
      answers[head] = answer(questions.fetch(head), match(questions.fetch(head), turn.target),
                             turn.target_confidence || turn.confidence)
    end
    { "answers" => answers, "model" => "scripted", "usage" => { "input_tokens" => 1 } }
  end

  private

  def match(question, target)
    offered = question.fetch("criteria")
    return offered.keys.first if target.nil?

    found = offered.find { |_, detail| detail["element"].to_s.include?(target) }
    raise "No offered target matching #{target.inspect} in #{offered.values.map { _1["element"] }.inspect}" unless found

    found.first
  end

  # Spreads the remaining mass evenly and refuses to build a distribution where the named choice is
  # not the argmax — that answer would be malformed, and a test should not be able to ask for one.
  def answer(question, choice, confidence)
    offered = question.fetch("criteria").keys
    raise "#{choice.inspect} is not offered: #{offered.inspect}" unless offered.include?(choice)

    others = offered.length - 1
    # A lone option holds all the mass, whatever the confidence in it. Confidence and probability are
    # different claims, and conflating them is what made the first draft of this fake unusable.
    return single(choice, confidence) if others.zero?

    share = (1.0 - confidence) / others
    if share > confidence + 1e-9
      raise "confidence #{confidence} is too low to be the argmax of #{offered.length} options " \
            "(each other option would hold #{share.round(3)})"
    end

    probabilities = offered.to_h { |key| [key, key == choice ? confidence : share] }
    { "type" => "choice", "choice" => choice, "confidence" => confidence, "probabilities" => probabilities }
  end

  def single(choice, confidence)
    { "type" => "choice", "choice" => choice, "confidence" => confidence, "probabilities" => { choice => 1.0 } }
  end
end

# Wraps a session so a test can make the page go stale underneath a decision, which is the one
# failure the run loop is allowed to retry.
class FlakySession
  def initialize(session, stale_acts: 0)
    @session = session
    @stale_acts = stale_acts
  end

  def act(*, **)
    if @stale_acts.positive?
      @stale_acts -= 1
      raise Wrangle::StalePage, "Page changed since this decision. Observe again."
    end
    @session.act(*, **)
  end

  def respond_to_missing?(name, include_private = false) = @session.respond_to?(name, include_private) || super

  def method_missing(name, ...)
    return super unless @session.respond_to?(name)

    @session.public_send(name, ...)
  end
end
