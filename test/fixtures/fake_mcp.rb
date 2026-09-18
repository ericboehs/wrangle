# frozen_string_literal: true

# A stand-in for `safaridriver --mcp`: JSON-RPC 2.0 over stdio, one message per line.
#
# It is not a Safari simulator. It answers the handshake and the four tools the bridge actually
# calls, and it can be told to misbehave in the specific ways a real server has — refusing a method,
# reporting a tool error, returning junk instead of JSON, going silent, dying mid-request, or losing
# the installed page runtime when the document is replaced. Every misbehaviour comes from a config
# file so a test can describe the failure it wants without a second fake.
require "json"

class FakeMcp
  MISSING = "__wrangle_runtime_missing__"

  def initialize(config)
    @config = config
    @installed = false
    @handle = "tab-1"
    # How many page requests are answered as "the runtime is gone" before one succeeds, which is
    # what a document replacement looks like from the bridge's side.
    @missing = config["runtime_missing"].to_i
  end

  def run
    while (line = $stdin.gets)
      message = parse(line) or next

      trace(message)
      answer = dispatch(message)
      next unless answer

      puts JSON.generate(answer)
      $stdout.flush
    end
  end

  private

  def parse(line)
    JSON.parse(line)
  rescue JSON::ParserError
    nil
  end

  def trace(message)
    return unless @config["trace"]

    File.open(@config["trace"], "a") { |file| file.puts(JSON.generate(message)) }
  end

  def dispatch(message)
    case message["method"]
    when "notifications/initialized" then nil
    when "initialize" then handshake(message["id"])
    when "tools/call" then call(message["id"], message["params"] || {})
    else error(message["id"], -32_601, "no such method")
    end
  end

  def handshake(id)
    return error(id, -32_000, "no automation for you") if @config["refuse_initialize"]

    reply(id, { "protocolVersion" => "2024-11-05", "serverInfo" => { "name" => "fake" } })
  end

  def call(id, params)
    arguments = params["arguments"] || {}
    case params["name"]
    when "navigate_to_url" then navigated(id)
    when "list_tabs" then tab_list(id)
    when "close_tab" then text(id, "closed")
    when "evaluate_javascript" then evaluate(id, arguments["expression"].to_s)
    else failed(id, "unknown tool #{params["name"]}")
    end
  end

  def navigated(id)
    @installed = false
    text(id, "navigated")
  end

  def tab_list(id)
    listed = [{ "handle" => @handle, "url" => @config["url"] || "https://fixture.test/stays" }]
    return text(id, "not json at all") if @config["bad_tab_list"]
    # Valid JSON that is not a list. A caller that trusts the parse and not the shape gets a
    # NoMethodError several layers away from here.
    return text(id, JSON.generate({ "handle" => @handle })) if @config["tab_list_not_an_array"]

    text(id, JSON.generate(listed))
  end

  # A server that accepts a page request and never answers, and one that dies holding it. Both have
  # happened to safaridriver, and both look the same from the bridge's side: a hang.
  def evaluate(id, expression)
    return install(id) if expression.include?("__wrangleSnapshot = ")
    return nil if @config["silent"]

    exit!(0) if @config["die"]
    return failed(id, "JavaScript exception") if @config["tool_error"]
    return evaluated(id, "<html>not json</html>") if @config["bad_json"]
    # Valid JSON, but not a result: no status to act on, so there is nothing to decode.
    return evaluated(id, JSON.generate({ "op" => "observe" })) if @config["statusless"]
    # A tool reply whose content is present but carries no text at all.
    return reply(id, { "content" => [{ "type" => "image" }] }) if @config["textless"]
    return vanished(id) if !@installed || @missing.positive?

    request = JSON.parse(expression[/__wrangleRun\((\{.*?\})\)/, 1] || "{}")
    evaluated(id, JSON.generate({ "status" => "ok", "op" => request["op"], "echo" => request }))
  end

  def install(id)
    @installed = true
    text(id, "installed")
  end

  def vanished(id)
    @missing -= 1 if @missing.positive?
    evaluated(id, MISSING)
  end

  def reply(id, result) = { "jsonrpc" => "2.0", "id" => id, "result" => result }
  def text(id, body) = reply(id, { "content" => [{ "type" => "text", "text" => body }] })
  def failed(id, body) = reply(id, { "isError" => true, "content" => [{ "type" => "text", "text" => body }] })
  def error(id, code, message) = { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => code, "message" => message } }

  # What `evaluate_javascript` hands back is the script's return value, serialised — and page.js
  # returns a JSON string, so the text of the reply is a JSON string *containing* JSON. The bridge
  # decodes both layers, and a fake that encoded only one would let a double-decode bug through.
  # `list_tabs` is the other shape: its text is the data itself.
  def evaluated(id, inner) = text(id, JSON.generate(inner))
end

config = ARGV[0] && File.exist?(ARGV[0]) ? JSON.parse(File.read(ARGV[0])) : {}
FakeMcp.new(config).run
