#!/usr/bin/env ruby
# frozen_string_literal: true

# A stand-in for `osascript -l JavaScript bridge.js` that simulates Safari and one page.
#
# It speaks the same newline-delimited JSON protocol as the real bridge, so the transport, the scope
# rules, and the delivery-resolution paths can all be tested without touching a browser. Behaviour is
# steered by a JSON config named in FAKE_BRIDGE_CONFIG, which lets a test ask for a hang, a death, or
# an action that never confirms.

require "json"

# The real snapshot labels a page key by what each part proves, and the freshness check names the
# part that moved. A fake carrying an opaque string would let every stale decision report the same
# thing and still pass.
PAGE_KEY = { "doc" => ["t0", "https://fixture.test/stays"], "view" => [0, 0, 1024, 768], "form" => [] }.freeze

def guard_for(value) = { "self" => ["n", "button", value], "scope" => "row #{value}" }
ACTIONS = [
  { "id" => "a1", "kind" => "fill", "node" => 1, "role" => "textbox", "label" => "Destination" },
  { "id" => "a2", "kind" => "select", "node" => 3, "role" => "combobox", "label" => "Category → Design",
    "value" => "Design" },
  { "id" => "a3", "kind" => "click", "node" => 2, "role" => "button", "label" => "Find stays" },
  { "id" => "a4", "kind" => "scroll", "delta" => 400, "label" => "Scroll down" },
  # snapshot.js offers this on every page, so a fake that never does is not the page that ships.
  { "id" => "wait", "kind" => "wait", "label" => "Wait for the page to update" }
].freeze

class Refusal < StandardError
  attr_reader :code

  def initialize(code, message)
    super(message)
    @code = code
  end
end

class Silence < StandardError; end

# The parts of page.js that matter to the Ruby side.
class Page
  # A page can offer an action Wrangle cannot carry out: a select with no value, a scroll of zero, a
  # control whose node never reached the snapshot. Those are refused on the way out rather than
  # dispatched and hoped for, so a fake has to be able to offer them.
  class << self
    attr_accessor :extra
  end
  self.extra = []

  attr_accessor :epoch, :act
  attr_reader :url

  PAGE_HEIGHT = 2400

  def initialize(url)
    @url = url
    @epoch = nil
    @text = "Find a place to slow down"
    @scroll = 0
    @revision = 0
    @filled = ""
    @act = nil
  end

  def state
    {
      "url" => @url, "title" => "Forma", "text" => @text,
      "actions" => ACTIONS.map(&:dup) + Page.extra.map(&:dup), "scroll" => { "y" => @scroll, "height" => PAGE_HEIGHT },
      "marker" => "m-#{@revision}", "page_key" => PAGE_KEY,
      "guards" => { "1" => guard_for("g1-#{@revision}"), "2" => guard_for("g2"),
                    "3" => guard_for("g3-#{@revision}") }
    }
  end

  # A settle watches the fingerprint, and the fingerprint is url, text, actions and scroll — not the
  # marker. A drift that only bumped the revision would be invisible to the thing it is meant to test.
  def drift!(arriving = nil)
    @revision += 1
    @text = "#{@text.sub(/ \(loading \d+\)\z/, "")} (loading #{@revision})"
    # What the caller is waiting for, landing partway through the drift rather than at the end of it.
    @text = "#{arriving} #{@text}" if arriving
  end

  def apply(action, text)
    case action["kind"]
    when "fill" then @filled = text
                     @text = "Find a place to slow down #{text}"
    when "select" then @text = "#{@text} [#{action["value"]}]"
    when "click" then @text = "1 places in #{@filled.empty? ? "nowhere" : @filled}"
    when "scroll" then @scroll = (@scroll + action["delta"]).clamp(0, PAGE_HEIGHT)
    end
    @revision += 1
  end
end

class FakeSafari
  attr_reader :windows, :closed, :bounds_calls
  attr_accessor :scripts

  def initialize(config)
    @next_id = 1000
    @windows = {}
    @closed = []
    @bounds_calls = []
    @scripts = nil
    Array(config["windows"]).each { |spec| add(spec["url"], tabs: spec["tabs"] || 1, window_id: spec["window_id"]) }
  end

  def add(url, tabs: 1, window_id: nil)
    @next_id += 4
    id = window_id || @next_id
    @windows[id] = { "window_id" => id, "tabs" => tabs, "tab_index" => 1, "url" => url,
                     "title" => "Forma", "bounds" => [0, 0, 1200, 800], "page" => Page.new(url) }
  end

  def close(id)
    @closed << id
    @windows.delete(id)
  end
end

class FakeBridge
  def initialize(config)
    @config = config
    @safari = FakeSafari.new(config)
    @reads = 0
    @drifts = config["drifts"].to_i
    @drifted = 0
    @scope_checks = 0
  end

  def handle(request)
    case request["op"]
    when "ping" then ping
    when "scripts" then install_scripts(request)
    when "displays" then { "displays" => [{ "x" => 0, "y" => 31, "width" => 1440, "height" => 2529 },
                                          { "x" => -1920, "y" => 351, "width" => 1920, "height" => 1080 }] }
    when "windows" then { "windows" => list_windows(request) }
    when "open" then opened(@safari.add(request["url"]))
    when "attach" then attach(request)
    when "bounds" then @safari.bounds_calls << request
                       { "bounds" => [-1920, 351, 1920, 1080] }
    when "eval" then evaluate(request)
    when "close" then close(request)
    else raise Refusal.new("bad_request", "Unknown op #{request["op"].inspect}")
    end
  end

  private

  def install_scripts(request)
    unless request["page"].is_a?(String) && request["snapshot"].is_a?(String)
      raise Refusal.new("bad_request", "scripts needs page and snapshot sources")
    end

    @safari.scripts = [request["page"].bytesize, request["snapshot"].bytesize]
    { "installed" => true }
  end

  def list_windows(request)
    @safari.windows.values.map do |window|
      described = window.slice("window_id", "tabs", "tab_index", "bounds").merge("display" => 0)
      request["titles"] == true ? described.merge(window.slice("url", "title")) : described
    end
  end

  # Safari's own reply, or something that is not one. A ping that is not a hash cannot be read for
  # an instance count, and guessing there is only one is how you end up driving the wrong window.
  def ping
    return "not a hash at all" if @config["ping_not_a_hash"]

    { "pid" => Process.pid, "safari_running" => true,
      "safari_instances" => @config.fetch("safari_instances", 1) }
  end

  def opened(window)
    fields = window.slice("window_id", "tab_index", "tabs", "url", "title", "bounds")
    # Safari can answer an open with a window that has no address yet, and with no id at all.
    fields.delete("url") if @config["open_without_url"]
    fields.delete("window_id") if @config["open_without_window_id"]
    fields
  end

  def attach(request)
    window = @safari.windows[request["window_id"]]
    raise Refusal.new("window_gone", "The scoped Safari window no longer exists") unless window
    if request["url"].is_a?(String) && window["url"] != request["url"]
      raise Refusal.new("scope_changed", "The scoped Safari tab is showing a different page")
    end

    window.slice("window_id", "tab_index", "tabs", "url", "title")
  end

  def close(request)
    # Not a scope problem: something went wrong that the caller has not been told about, and a close
    # that fails for a reason nobody understands is worth raising rather than swallowing.
    raise Refusal.new("bad_request", "Safari refused to close the window") if @config["close_fails"]
    raise Refusal.new("bad_request", "Refusing to close a window this bridge does not own") unless request["owned"]

    window = @safari.windows[request["window_id"]]
    return { "closed" => nil } unless window
    raise Refusal.new("scope_changed", "The owned window gained tabs; leaving it open") if window["tabs"] != 1

    @safari.close(request["window_id"])
    { "closed" => request["window_id"] }
  end

  def evaluate(request)
    window = scoped(request["scope"], verify: request["verify"] == true)
    raise Refusal.new("bad_request", "eval needs a payload") unless request["payload"].is_a?(String)
    raise Refusal.new("bad_request", "Install the page scripts first") unless @safari.scripts

    # What a page can hand back when a script is broken or a document is mid-swap: nothing at all,
    # something that is not JSON, or JSON that is not the result shape the protocol promises.
    case @config["page_result"]
    when "missing" then return {}
    when "unparsable" then return { "result" => "<!DOCTYPE html>" }
    when "wrong_shape" then return { "result" => JSON.generate([1, 2, 3]) }
    when "statusless" then return { "result" => JSON.generate({ "state" => {} }) }
    end

    { "result" => JSON.generate(page_request(window, JSON.parse(request["payload"]))) }
  end

  # Scope enforcement mirrors bridge.js: window, tab count or position, then expected URL.
  def scoped(scope, verify:)
    raise Refusal.new("bad_request", "A scope needs a window_id") unless scope.is_a?(Hash) &&
                                                                         scope["window_id"].is_a?(Integer)

    window = @safari.windows[scope["window_id"]]
    raise Refusal.new("window_gone", "The scoped Safari window no longer answers") unless window

    @scope_checks += 1
    grow = @config["grow_tabs_after"]
    window["tabs"] += 1 if grow.is_a?(Integer) && @scope_checks > grow

    if scope["mode"] == "dedicated" && window["tabs"] != 1
      raise Refusal.new("scope_changed", "The dedicated Safari window now holds #{window["tabs"]} tabs")
    end
    if scope["mode"] != "dedicated" && scope["tab_index"].is_a?(Integer) && window["tab_index"] != scope["tab_index"]
      raise Refusal.new("scope_changed", "A different tab is now current in the scoped Safari window")
    end
    if verify && scope["url"].is_a?(String) && window["url"] != scope["url"]
      raise Refusal.new("scope_changed", "The scoped Safari tab is showing a different page")
    end

    window
  end

  # A test that wants a stale decision says which part of the guard moved, because the whole point of
  # the check is that it can tell them apart.
  def guard_reply(page, node)
    key = PAGE_KEY.dup
    guard = page.state["guards"][node.to_s]
    Array(@config["guard_moved"]).each do |moved|
      case moved
      when "origin" then key["origin"] = "t1"
      when "route" then key["route"] = "https://fixture.test/somewhere-else"
      when "view" then key["view"] = [0, 400, 1024, 768]
      when "form" then key["form"] = [[1, "typed", nil, nil, false, false]]
      when "self" then guard = guard.merge("self" => ["n", "button", "a different label"])
      when "scope" then guard = guard.merge("scope" => "a different row")
      when "gone" then guard = nil
      end
    end
    [key, guard]
  end

  def page_request(window, request)
    page = window["page"]
    if request["op"] == "install"
      # A document that will not take the binding: the observe loop must give up rather than spin.
      return { "status" => "install_failed" } if @config["install_fails"]

      page.epoch = request["epoch"]
      @reads = 0 # A fresh binding restarts the countdown a test asked for.
      return { "status" => "ok", "state" => page.state }
    end

    @reads += 1
    forget = @config["forget_epoch_after"]
    page.epoch = nil if forget.is_a?(Integer) && @reads > forget
    # The document survived, but it is not the one that was observed: a reload between the read and
    # the dispatch. Nothing has been mutated yet, and nothing should be.
    page.epoch = "e-reloaded" if @config["reload_before_act"] && request["op"] == "act"
    return { "status" => "epoch_lost" } if page.epoch.nil? || page.epoch != request["epoch"]

    # A page mid-load answers its own ops with something other than "ok", and a freshness check that
    # reads that as "unchanged" would wave through a decision about a document that is not there yet.
    return { "status" => "loading" } if request["op"] == @config["loading_on"]

    case request["op"]
    when "observe" then observed(page)
    when "marker" then { "status" => "ok", "marker" => page.state["marker"] }
    when "guard" then { "status" => "ok", "guard" => guard_reply(page, request["node"]) }
    when "probe" then { "status" => "ok", "act" => page.act }
    when "act" then act(page, request)
    else raise Refusal.new("bad_request", "Unknown page op #{request["op"].inspect}")
    end
  end

  def observed(page)
    # A page that keeps changing for a few reads and then stops, which is what a settle is for: a
    # results list arriving, a price rendering, a banner pushing the page down.
    if @drifts.positive? && (@drifts -= 1) >= 0
      @drifted += 1
      page.drift!(@drifted == @config["appears_after"] ? @config["appears"] : nil)
    end
    # A snapshot missing a key the protocol promises is not an observation, however well it parses.
    state = @config["incomplete_state"] ? page.state.tap { _1.delete("actions") } : page.state
    { "status" => "ok", "state" => state }
  end

  def act(page, request)
    nonce = request["nonce"]
    page.act = { "nonce" => nonce, "phase" => "started" }
    case @config.fetch("act", "normal")
    when "blocked" then page.act = nil
                        { "status" => "blocked", "reason" => "covered" }
    when "started_then_silent" then raise Silence
    when "finished_then_silent"
      page.apply(request["action"], request["text"])
      page.act = { "nonce" => nonce, "phase" => "finished" }
      raise Silence
    when "forgotten_then_silent" then page.act = nil
                                      raise Silence
    when "unconfirmed" then { "status" => "dispatched" }
    when "nonsense" then { "status" => "confused" }
    # The action goes out, the reply never comes, and the probe that would settle it cannot be read
    # either. Nothing here can know whether the page was touched.
    when "silent_then_unreadable" then @config["loading_on"] = "probe"
                                       raise Silence
    # Dispatched, and then the bridge is gone. There is nothing left to ask about it.
    when "started_then_dead" then exit!(0)
    else
      page.apply(request["action"], request["text"])
      page.act = { "nonce" => nonce, "phase" => "finished" }
      { "status" => "executed" }
    end
  end
end

config = ENV["FAKE_BRIDGE_CONFIG"] ? JSON.parse(File.read(ENV["FAKE_BRIDGE_CONFIG"])) : {}
Page.extra = Array(config["extra_actions"])
bridge = FakeBridge.new(config)
$stdout.sync = true

$stdin.each_line do |line|
  line = line.strip
  next if line.empty?

  request = JSON.parse(line)
  op = request["op"]
  File.open(config["trace"], "a") { |f| f.puts(JSON.generate(request)) } if config["trace"]

  # Whatever Safari would have complained about, and as much of it as the config asks for. It is the
  # only explanation a caller gets when the bridge then dies without answering, and a bridge that
  # chatters must not be allowed to grow an unbounded transcript in the process that is reading it.
  if op == config["stderr_on"]
    Array.new(config["stderr_flood"].to_i) { warn("noise #{_1}") }
    warn "osascript: something went wrong"
  end
  exit 0 if op == "exit" || op == config["die_on"]
  # A reply to a request that was already abandoned, arriving under an id nobody is waiting for.
  puts JSON.generate({ "id" => request["id"] - 1, "ok" => true, "late" => true }) if op == config["late_reply_on"]
  next if op == config["hang_on"]

  if op == config["garbage_on"]
    puts "this is not json"
    next
  end
  # A line too long to hold, and a reply that parses but is not a response object. Both are things a
  # real bridge can emit when a page is enormous or a script returns the wrong thing.
  if op == config["oversized_on"]
    puts("x" * (4_000_000 + 1)) # JxaBridge::MAX_LINE_BYTES, which this process cannot see.
    next
  end
  if op == config["nonobject_on"]
    puts JSON.generate([1, 2, 3])
    next
  end
  puts JSON.generate({ "id" => 0, "ok" => true, "value" => {} }) if op == config["stale_reply_on"]

  response = begin
    { "id" => request["id"], "ok" => true, "value" => bridge.handle(request) }
  rescue Refusal => e
    { "id" => request["id"], "ok" => false, "code" => e.code, "error" => e.message }
  rescue Silence
    next
  end
  puts JSON.generate(response)
end
