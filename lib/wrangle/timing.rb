# frozen_string_literal: true

module Wrangle
  # Real monotonic time and sleeping are defaults, not hard-coded dependencies. Tests and embedded
  # callers can supply the same two-method interface to advance deadlines deterministically.
  module Timing
    module_function

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def sleep(seconds) = Kernel.sleep(seconds)
  end
end
