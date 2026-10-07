# frozen_string_literal: true

require "json"
require "open3"
require "test_helper"

# A bridge started from a Background launchd session (a tmux server that outlived its login, say)
# gets an empty LaunchServices view of GUI apps. NSWorkspace then reports no frontmost application
# and no Safari, even though Apple Events still reach both. `open` placed its window, threw on
# `prior.activateWithOptions` because a JXA nil is truthy, and on getting past that, refused with
# safari_not_running. These run the bridge's helpers under node with stand-ins for the JXA globals,
# so those paths are held without Safari or a Background session.
class BridgeLaunchServicesTest < Minitest::Test
  BRIDGE = File.expand_path("../lib/wrangle/js/bridge.js", __dir__)

  HARNESS = <<~JS
    const fs = require('fs');
    const vm = require('vm');
    const scenario = JSON.parse(process.argv[2]);
    const calls = [];
    const nil = Object.assign(function () {}, { isNil: () => true });
    const app = (name) => ({ name, isNil: () => false, activateWithOptions: (o) => calls.push(`activate ${name} ${o}`) });
    const running = (scenario.workspaceApps || []).map(([bundleIdentifier, processIdentifier]) => ({ bundleIdentifier, processIdentifier }));
    const $ = Object.assign(function () {}, {
      NSFileHandle: { fileHandleWithStandardInput: {}, fileHandleWithStandardOutput: {} },
      NSWorkspace: { sharedWorkspace: {
        frontmostApplication: scenario.workspaceFront === 'nil' ? nil : app('workspace-front'),
        runningApplications: running
      } }
    });
    const Application = (name) => {
      calls.push(`application ${name}`);
      if (scenario.systemEvents === 'throws') throw new Error('not authorized');
      return { processes: { whose: (filter) => {
        calls.push(`whose ${JSON.stringify(filter)}`);
        return { unixId: () => scenario.systemEventsPids || [] };
      } } };
    };
    const context = vm.createContext({ $, Application, ObjC: { import: () => {}, unwrap: (v) => v } });
    vm.runInContext(fs.readFileSync(process.argv[1], 'utf8'), context);
    const result = { calls };
    try {
      if (scenario.op === 'safari') {
        result.instances = vm.runInContext('safariInstances()', context);
      } else {
        const prior = vm.runInContext('frontmostApplication()', context);
        result.prior = prior ? prior.name : null;
        const given = { nil, missing: { isNil: () => false }, throws: { isNil: () => false, activateWithOptions: () => { throw new Error('gone'); } } };
        context.prior = scenario.restore ? given[scenario.restore] : prior;
        vm.runInContext('restoreFocus(prior)', context);
      }
    } catch (e) { result.error = String(e); }
    console.log(JSON.stringify(result));
  JS

  def setup
    skip "node is not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)
  end

  def bridge(**scenario)
    out, err, status = Open3.capture3("node", "-e", HARNESS, BRIDGE, JSON.generate(scenario))
    assert status.success?, err
    JSON.parse(out).tap { |result| assert_nil result["error"] }
  end

  def test_the_frontmost_application_gets_focus_back_after_open
    result = bridge(op: "focus", workspaceFront: "app")

    assert_equal "workspace-front", result["prior"]
    assert_equal ["activate workspace-front 0"], result["calls"]
  end

  def test_a_nil_frontmost_application_is_not_mistaken_for_one
    result = bridge(op: "focus", workspaceFront: "nil")

    assert_nil result["prior"]
    assert_empty result["calls"]
  end

  def test_restoring_focus_never_fails_the_open
    %w[nil missing throws].each { |restore| bridge(op: "focus", workspaceFront: "app", restore:) }
  end

  def test_safari_listed_by_nsworkspace_needs_no_system_events
    result = bridge(op: "safari", workspaceApps: [["com.apple.Finder", 10], ["com.apple.Safari", 59_263]])

    assert_equal [59_263], result["instances"]
    assert_empty result["calls"]
  end

  def test_safari_missing_from_nsworkspace_is_found_through_system_events
    result = bridge(op: "safari", workspaceApps: [["com.apple.Finder", 10]], systemEventsPids: [59_263])

    assert_equal [59_263], result["instances"]
    assert_equal ["application System Events", 'whose {"bundleIdentifier":"com.apple.Safari"}'], result["calls"]
  end

  def test_safari_running_nowhere_is_reported_as_not_running
    assert_empty bridge(op: "safari", systemEventsPids: [])["instances"]
    assert_empty bridge(op: "safari", systemEvents: "throws")["instances"]
  end
end
