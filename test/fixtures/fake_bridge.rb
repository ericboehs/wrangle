#!/usr/bin/env ruby
# frozen_string_literal: true

# A stand-in for `osascript -l JavaScript bridge.js` that simulates Safari and one page.
#
# It speaks the same newline-delimited JSON protocol as the real bridge, so the transport, the scope
# rules, and the delivery-resolution paths can all be tested without touching a browser. Behaviour is
# steered by a JSON config named in FAKE_BRIDGE_CONFIG, which lets a test ask for a hang, a death, or
# an action that never confirms.

require "json"

PAGE_KEY = "pk-1"
ACTIONS = [
  { "id" => "a1", "kind" => "fill", "node" => 1, "role" => "textbox", "label" => "Destination" },
  { "id" => "a2", "kind" => "select", "node" => 3, "role" => "combobox", "label" => "Category → Design",
    "value" => "Design" },
  { "id" => "a3", "kind" => "click", "node" => 2, "role" => "button", "label" => "Find stays" },
  { "id" => "a4", "kind" => "scroll", "delta" => 400, "label" => "Scroll down" }
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
  attr_accessor :epoch, :act
  attr_reader :url

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
      "actions" => ACTIONS.map(&:dup), "scroll" => @scroll,
      "marker" => "m-#{@revision}", "page_key" => PAGE_KEY,
      "guards" => { "1" => "g1-#{@revision}", "2" => "g2", "3" => "g3-#{@revision}" }
    }
  end

  def apply(action, text)
    case action["kind"]
    when "fill" then @filled = text
                     @text = "Find a place to slow down #{text}"
    when "select" then @text = "#{@text} [#{action["value"]}]"
    when "click" then @text = "1 places in #{@filled.empty? ? "nowhere" : @filled}"
    when "scroll" then @scroll += action["delta"]
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
    @scope_checks = 0
  end

  def handle(request)
    case request["op"]
    when "ping" then { "pid" => Process.pid, "safari_running" => true,
                       "safari_instances" => @config.fetch("safari_instances", 1) }
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

  def opened(window)
    window.slice("window_id", "tab_index", "tabs", "url", "title", "bounds")
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

  def page_request(window, request)
    page = window["page"]
    if request["op"] == "install"
      page.epoch = request["epoch"]
      @reads = 0 # A fresh binding restarts the countdown a test asked for.
      return { "status" => "ok", "state" => page.state }
    end

    @reads += 1
    forget = @config["forget_epoch_after"]
    page.epoch = nil if forget.is_a?(Integer) && @reads > forget
    return { "status" => "epoch_lost" } if page.epoch.nil? || page.epoch != request["epoch"]

    case request["op"]
    when "observe" then { "status" => "ok", "state" => page.state }
    when "marker" then { "status" => "ok", "marker" => page.state["marker"] }
    when "guard" then { "status" => "ok", "guard" => [PAGE_KEY, page.state["guards"][request["node"].to_s]] }
    when "probe" then { "status" => "ok", "act" => page.act }
    when "act" then act(page, request)
    else raise Refusal.new("bad_request", "Unknown page op #{request["op"].inspect}")
    end
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
    else
      page.apply(request["action"], request["text"])
      page.act = { "nonce" => nonce, "phase" => "finished" }
      { "status" => "executed" }
    end
  end
end

config = ENV["FAKE_BRIDGE_CONFIG"] ? JSON.parse(File.read(ENV["FAKE_BRIDGE_CONFIG"])) : {}
bridge = FakeBridge.new(config)
$stdout.sync = true

$stdin.each_line do |line|
  line = line.strip
  next if line.empty?

  request = JSON.parse(line)
  op = request["op"]
  File.open(config["trace"], "a") { |f| f.puts(JSON.generate(request)) } if config["trace"]

  exit 0 if op == "exit" || op == config["die_on"]
  next if op == config["hang_on"]

  if op == config["garbage_on"]
    puts "this is not json"
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
