# frozen_string_literal: true

require "test_helper"

# The action space is what Jev is actually shown, so these tests are about the shape of that list
# rather than about any page. Two properties matter and both are easy to break by accident: one row
# per element however many things it supports, and a target that names an option the page really
# offered instead of a value the model composed.
class ActionSpaceTest < Minitest::Test
  def click(node, label, **extra) = { "id" => "e1", "node" => node, "kind" => "click", "label" => label, **extra }

  def fill(node, label, value = "")
    { "id" => "e2", "node" => node, "kind" => "fill", "label" => label, "value" => value }
  end

  def option(node, label, value, current: "Featured")
    { "id" => "e3", "node" => node, "kind" => "select", "label" => label, "value" => value,
      "current_value" => current }
  end

  # A combobox can be typed into and opened, and the snapshot emits an action for each. Repeating the
  # same label once per action is how a short list becomes a long one, and Jev loses accuracy as the
  # state fills with detail.
  def test_actions_sharing_a_node_collapse_into_one_element
    space = Wrangle::ActionSpace.new([fill(7, "Where to?"), click(7, "Open Where to?")])

    assert_equal 1, space.elements.length
    assert_equal %w[TYPE_TEXT CLICK], space.elements.first["operations"]
    assert_equal "Where to?", space.elements.first["label"]
  end

  def test_each_operation_can_be_aimed_at_the_elements_that_support_it
    space = Wrangle::ActionSpace.new([click(1, "Search"), fill(2, "Where to?"), click(2, "Open Where to?")])

    assert_equal %w[1 2], space.targets.fetch("CLICK").keys
    assert_equal %w[2], space.targets.fetch("TYPE_TEXT").keys
    assert_equal "Search", space.targets.dig("CLICK", "1")["label"]
  end

  # The value assigned to a select is never composed by the model: every option is a separate target,
  # so choosing one is choosing something the page listed.
  def test_a_select_offers_one_target_per_observed_option
    space = Wrangle::ActionSpace.new([option(9, "Sort by: → Price: Low to High", "price-asc-rank"),
                                      option(9, "Sort by: → Best Sellers", "popularity-rank")])

    assert_equal 1, space.elements.length
    # Element 1, options 1 and 2 — the element index the model is shown, not the page's node id.
    assert_equal %w[1:1 1:2], space.targets.fetch("SELECT").keys
    assert_equal(%w[price-asc-rank popularity-rank], space.elements.first["options"].map { _1["value"] })
    assert_equal "price-asc-rank", space.targets.dig("SELECT", "1:1")["value"]
  end

  def test_a_select_reports_what_is_currently_chosen_rather_than_an_option_value
    space = Wrangle::ActionSpace.new([option(9, "Sort by: → Price: Low to High", "price-asc-rank")])

    assert_equal "Featured", space.elements.first["value"]
    assert_equal "Sort by:", space.elements.first["label"]
  end

  # Waiting and scrolling are not aimed at anything, which is what lets the model say "this page is
  # still loading" instead of the harness sleeping a fixed interval on every step.
  def test_operations_without_a_target_become_controls_of_their_own
    space = Wrangle::ActionSpace.new([{ "id" => "wait", "kind" => "wait", "label" => "Wait for the page" },
                                      { "id" => "scroll_down", "kind" => "scroll", "label" => "Scroll down" }])

    assert_equal %w[WAIT SCROLL_DOWN], space.controls.keys
    assert_empty space.targets
    refute_predicate space, :empty?
  end

  def test_a_page_offering_nothing_at_all_is_empty
    assert_predicate Wrangle::ActionSpace.new([]), :empty?
  end

  # State the model needs in order to not toggle something that is already set. A checkbox that reads
  # as checked is the difference between confirming a choice and undoing it.
  def test_state_flags_travel_with_the_element
    space = Wrangle::ActionSpace.new([click(3, "Non-stop only", "role" => "checkbox", "checked" => "true")])

    assert_equal "checkbox", space.elements.first["role"]
    assert_equal "true", space.elements.first["checked"]
  end
end
