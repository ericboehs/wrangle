# frozen_string_literal: true

require_relative "wrangle/version"
require_relative "wrangle/errors"
require_relative "wrangle/timing"
require_relative "wrangle/observation"
require_relative "wrangle/desktop_observation"
require_relative "wrangle/desktop_policy"
require_relative "wrangle/decision_provider"
require_relative "wrangle/provider_qualification"
require_relative "wrangle/provider_factory"
require_relative "wrangle/desktop_decider"
require_relative "wrangle/desktop_autonomy"
require_relative "wrangle/desktop_session_autonomy"
require_relative "wrangle/desktop_dispatch"
require_relative "wrangle/desktop_effect"
require_relative "wrangle/desktop_proposal"
require_relative "wrangle/event_log"
require_relative "wrangle/scope_registry"
require_relative "wrangle/macos_helper"
require_relative "wrangle/macos_driver"
require_relative "wrangle/jxa_bridge"
require_relative "wrangle/mcp_bridge"
require_relative "wrangle/safari"
require_relative "wrangle/jev"
require_relative "wrangle/action_space"
require_relative "wrangle/decider"
require_relative "wrangle/session_server"
require_relative "wrangle/desktop_session_server"
require_relative "wrangle/desktop_task"

# Hand one Safari window to a program, and no more than that.
#
# Wrangle drives an ordinary Safari window through Apple Events. There is no automation session and
# no extension, so the window stays a real one the user can see, keep, and take back at any moment.
module Wrangle
end
