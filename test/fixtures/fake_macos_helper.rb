#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

mode = ARGV.shift
input = JSON.parse(ARGV.fetch(0, "{}"))
operation = input["op"]
version = mode == "protocol" ? "2.0" : "1.0"

if mode == "snapshot-refusal" && operation == "snapshot"
  puts JSON.generate("version" => version, "ok" => false,
                     "error" => { "code" => "action_not_supported",
                                  "message" => "native snapshot unavailable",
                                  "disposition" => { "delivery" => "not_delivered", "retry" => "unsafe" } })
  exit 1
end

value = case operation
        when "ping"
          { "platform" => "macos", "accessibility" => true, "session_locked" => false,
            "secret_present" => ENV.key?("JEV_API_KEY") }
        when "displays"
          bounds = { "x" => 0, "y" => 0, "width" => 100, "height" => 100 }
          { "displays" => [{ "id" => "display-1", "bounds" => bounds }] }
        when "windows"
          bounds = { "x" => 0, "y" => 0, "width" => 100, "height" => 100 }
          window = { "id" => "w-1", "app_name" => input["app"], "bundle_id" => "com.apple.finder",
                     "pid" => 42, "process_instance" => "proc-42", "bounds" => bounds,
                     "focused" => true, "visible" => true, "titles" => input["titles"] }
          { "windows" => [window] }
        when "frontmost"
          window = { "id" => "w-1", "app_name" => "Finder", "bundle_id" => "com.apple.finder",
                     "pid" => 42, "process_instance" => "proc-42", "bounds" => {},
                     "titles" => input["titles"] }
          { "window" => window }
        when "enable_accessibility"
          { "pid" => input["pid"], "process_instance" => input["process_instance"],
            "changed" => true, "verified" => true }
        when "snapshot"
          target = { "path" => [0], "role" => "button", "name" => "Native Open",
                     "operations" => { "PRESS" => "AXPress" } }
          { "snapshot_id" => "native-1", "complete" => true,
            "window" => { "id" => input["window_id"] }, "provenance" => %w[ax macos_helper_native],
            "tree" => { "role" => "window", "name" => "Fixture", "children" => [
              { "ref_id" => "@nnative1:e1", "role" => "button", "name" => "Native Open",
                "operations" => ["PRESS"], "target_key" => "native:0:button" }
            ] }, "targets" => { "@nnative1:e1" => target } }
        when "execute"
          { "dispatch" => mode == "bad-dispatch" ? "maybe" : "delivered", "driver" => "macos_helper_native",
            "operation" => input["operation"], "target" => input.dig("target", "name") }
        else {}
        end

case mode
when "driver", "protocol", "bad-dispatch", "snapshot-refusal"
  puts JSON.generate("version" => version, "ok" => true, "value" => value)
when "refusal"
  puts JSON.generate("version" => version, "ok" => false,
                     "error" => { "code" => "scope_changed", "message" => "Process changed",
                                  "suggestion" => "Attach again", "details" => { "pid" => 2 },
                                  "disposition" => { "delivery" => "not_delivered", "retry" => "unsafe" } })
  exit 1
when "bare-refusal"
  puts JSON.generate("version" => version, "ok" => false, "error" => {})
  exit 1
when "incomplete-refusal"
  puts JSON.generate("version" => version, "ok" => false, "error" => "bad")
  exit 1
when "invalid"
  puts "bad json"
when "array"
  puts "[]"
when "no-value"
  puts JSON.generate("version" => version, "ok" => true)
when "exit-two"
  puts JSON.generate("version" => version, "ok" => true, "value" => value)
  exit 2
else
  abort "unknown mode"
end
