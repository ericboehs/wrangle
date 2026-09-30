# frozen_string_literal: true

require_relative "test_helper"

class DesktopPolicyTest < Minitest::Test
  def setup
    @policy = Wrangle::DesktopPolicy.new
    @scope = Struct.new(:app).new("Slack")
  end

  def test_standard_action_is_permitted_without_approval
    result = assess("Open", "PRESS")

    assert result.permitted
    refute result.consequential
    assert_equal "standard", result.classification
    assert_equal({ "classification" => "standard", "consequential" => false, "permitted" => true }, result.to_h)
  end

  def test_consequential_labels_and_toggles_require_approval
    %w[Send Submit Delete Remove Trash Erase Buy Purchase Pay Confirm Save Allow Install].each do |label|
      result = assess(label, "PRESS")
      assert result.consequential, label
      assert result.permitted
      assert_equal "consequential", result.classification
      assert_match(/Slack action/, result.reason)
    end

    assert assess("Dark mode", "TOGGLE").consequential
    refute assess("Sender", "PRESS").consequential
  end

  def test_handed_over_window_controls_are_never_permitted
    ["Close", "Close Window", "Minimize", "Zoom", "Quit Slack"].each do |label|
      result = @policy.assess(scope: @scope, candidate: { "role" => "button", "label" => label },
                              operation: "PRESS")
      refute result.permitted, label
      assert result.consequential, label
      assert_equal "scope_violation", result.classification
      assert_match(/never closes or manages/, result.reason)
    end

    subrole = @policy.assess(scope: @scope,
                             candidate: { "role" => "button", "subrole" => "AXCloseButton", "label" => "" },
                             operation: "PRESS")
    refute subrole.permitted
    refute assess("Quit", "PRESS").permitted
  end

  def test_secret_text_is_a_handoff_not_an_input
    %w[Password Passcode Token Secret].each do |label|
      result = assess(label, "SET_TEXT")
      refute result.permitted
      assert result.consequential
      assert_equal "credential_handoff", result.classification
      assert_match(/password-manager/, result.reason)
    end

    assert assess("Password", "CLEAR").permitted
  end

  private

  def assess(label, operation)
    @policy.assess(scope: @scope, candidate: { "label" => label }, operation:)
  end
end
