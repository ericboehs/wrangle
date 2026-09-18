# frozen_string_literal: true

require_relative "wrangle/version"
require_relative "wrangle/errors"
require_relative "wrangle/observation"
require_relative "wrangle/jxa_bridge"
require_relative "wrangle/safari"
require_relative "wrangle/session_server"

# Hand one Safari window to a program, and no more than that.
#
# Wrangle drives an ordinary Safari window through Apple Events. There is no automation session and
# no extension, so the window stays a real one the user can see, keep, and take back at any moment.
module Wrangle
end
