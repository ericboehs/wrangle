# frozen_string_literal: true

require "test_helper"

class ObservationTest < Minitest::Test
  PAGE = {
    "url" => "https://fixture.test/", "title" => "Forma", "text" => "one result",
    "scroll" => 0, "marker" => "m-1", "page_key" => "pk-1", "guards" => { "1" => "g1" },
    "actions" => [{ "id" => "a1", "kind" => "fill", "node" => 1, "label" => "Destination" },
                  { "id" => "a2", "kind" => "click", "node" => 2, "label" => "Find stays" }]
  }.freeze

  def test_a_fingerprint_ignores_key_order_but_not_content
    reordered = PAGE.to_a.reverse.to_h
    assert_equal Wrangle::Observation.fingerprint(PAGE), Wrangle::Observation.fingerprint(reordered)

    moved = PAGE.merge("scroll" => 400)
    refute_equal Wrangle::Observation.fingerprint(PAGE), Wrangle::Observation.fingerprint(moved)

    # The title is deliberately not fingerprinted: it changes without the page's controls changing.
    retitled = PAGE.merge("title" => "Forma - 1 result")
    assert_equal Wrangle::Observation.fingerprint(PAGE), Wrangle::Observation.fingerprint(retitled)
  end

  def test_an_action_must_be_an_exact_candidate_from_the_observed_page
    observed = PAGE["actions"].first
    assert_equal observed, Wrangle::Observation.require_observed(observed, PAGE)

    # This is the boundary that stops model output from becoming instructions.
    assert_raises(ArgumentError) { Wrangle::Observation.require_observed(observed.merge("node" => 99), PAGE) }
    assert_raises(ArgumentError) { Wrangle::Observation.require_observed({ "id" => "a9" }, PAGE) }
    assert_raises(ArgumentError) { Wrangle::Observation.require_observed({ "kind" => "click" }, PAGE) }
    assert_raises(ArgumentError) { Wrangle::Observation.require_observed(observed, { "actions" => "none" }) }
    assert_raises(ArgumentError) { Wrangle::Observation.require_observed("click it", PAGE) }
  end

  def test_an_ambiguous_candidate_is_refused_rather_than_guessed
    duplicated = PAGE.merge("actions" => [PAGE["actions"].first, PAGE["actions"].first])
    assert_raises(ArgumentError) { Wrangle::Observation.require_observed(PAGE["actions"].first, duplicated) }
  end

  def test_a_page_request_travels_as_json_not_as_program_text
    hostile = { "op" => "act", "text" => '"); alert(1); //', "action" => { "id" => "a1" } }
    payload = Wrangle::JxaBridge.new.payload(hostile)

    assert_equal hostile, JSON.parse(payload)
    assert_includes payload, '\\"); alert(1)' # the quote that would end the argument is escaped
    refute_includes payload, "\n"
  end

  def test_the_composed_program_passes_hostile_text_as_one_argument
    skip "node is needed to evaluate the composed program" unless system("which node > /dev/null 2>&1")

    hostile = { "op" => "act", "text" => '"); globalThis.escaped = true; //', "action" => { "id" => "a1" } }
    payload = Wrangle::JxaBridge.new.payload(hostile)
    # This is the exact composition bridge.js performs: `(page)(payload, () => (snapshot))`.
    program = "const received = ((request, observe) => request)(#{payload}, () => (0));\n" \
              "if (globalThis.escaped) throw new Error('the payload escaped its argument');\n" \
              "process.stdout.write(received.text);\n"

    Dir.mktmpdir do |dir|
      file = File.join(dir, "composed.js")
      File.write(file, program)
      assert_equal hostile["text"], `node #{file}`
      assert_predicate $CHILD_STATUS, :success?
    end
  end
end
