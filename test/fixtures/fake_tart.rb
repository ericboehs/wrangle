#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

case ARGV
when ["list", "--format", "json"]
  puts JSON.generate([{ "Name" => "fixture-vm", "Running" => true,
                        "State" => "running", "Source" => "local" }])
when ["exec", "fixture-vm", "/usr/sbin/sysctl", "-n", "kern.boottime"]
  puts "{ sec = 1790200000, usec = 123456 } Tue Sep 23 19:00:00 2026"
else
  exec(*ARGV.drop(2)) if ARGV[0, 2] == %w[exec fixture-vm] && ARGV.length >= 4

  warn "unsupported fake tart invocation"
  exit 2
end
