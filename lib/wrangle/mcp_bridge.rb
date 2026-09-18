# frozen_string_literal: true

require "json"
require "monitor"
require "timeout"

require_relative "errors"

module Wrangle
  # Drives Safari through `safaridriver --mcp` instead of Apple Events.
  #
  # Safari 27 ships an MCP server over stdio, and its `evaluate_javascript` tool is enough to run the
  # same `snapshot.js` and `page.js` the Apple Events bridge uses. So this is a transport swap, not a
  # second implementation of the page protocol: the JavaScript, the epoch guard, and the action ids
  # are identical, and only the pipe underneath changes.
  #
  # It is opt-in. The automation server drives its own isolated tab, which means it cannot see the
  # windows you already have open — including whatever you are signed into. That isolation is the
  # reason to want it and the reason it is not the default.
  #
  # Cost shape, measured on this machine: the first navigation pays about six seconds to bring the
  # automation browser up, after which an act costs ~3 ms against Apple Events' ~120 ms. It wins on
  # sessions of roughly thirty actions or more and loses on short ones.
  class McpBridge
    COMMAND = ["/usr/bin/safaridriver", "--mcp"].freeze
    PROTOCOL = "2024-11-05"
    SCRIPTS = File.expand_path("js", __dir__)
    MISSING = "__wrangle_runtime_missing__"
    # Ops that only read. A mutation is never re-dispatched, so only these may be retried after the
    # runtime is reinstalled.
    READ_ONLY = %w[install observe marker guard probe].freeze

    def initialize(command: COMMAND, request_timeout: 30, startup_timeout: 25)
      @command = command
      @request_timeout = request_timeout
      @startup_timeout = startup_timeout
      @lock = Monitor.new
      @next_id = 1
      @started = false
      @closed = false
      @stderr = []
      @handle = nil
    end

    def running? = !@io.nil? && !@io.closed? && !@closed

    def stderr = @stderr.dup

    # Bring the server up and handshake. Returns the Safari instance count the session guard expects;
    # the automation browser is its own instance, so window ids are never ambiguous here.
    def start
      @lock.synchronize do
        next 1 if @started

        spawn_process
        rpc("initialize", { protocolVersion: PROTOCOL, capabilities: {},
                            clientInfo: { name: "wrangle", version: Wrangle::VERSION } }, @startup_timeout)
        notify("notifications/initialized")
        @started = true
        1
      end
    end

    def request(op, timeout: nil, **params)
      @lock.synchronize do
        start unless @started
        case op.to_s
        when "ping" then { "ok" => true }
        when "open" then open_tab(params, timeout)
        when "close" then close_tab
        when "windows" then { "windows" => tabs }
        when "attach"
          raise BridgeCallError.new("unsupported", "The MCP backend drives its own tab and cannot " \
                                                   "attach to a window you already have open.")
        when "displays", "bounds"
          raise BridgeCallError.new("unsupported", "The MCP backend has no window geometry; " \
                                                   "use the Apple Events backend for --display.")
        else
          raise BridgeCallError.new("unsupported", "The MCP backend does not support #{op.inspect}")
        end
      end
    end

    # Run one code-owned page request and decode its JSON reply, exactly as the Apple Events bridge
    # does. `verify` is unnecessary here: the JSON-RPC reply is itself the acknowledgement, so a
    # request that returns at all was delivered.
    def evaluate(scope, page_request, verify: false, timeout: nil) # rubocop:disable Lint/UnusedMethodArgument
      raise ArgumentError, "Bridge evaluation needs a scope and a request" unless scope.is_a?(Hash) &&
                                                                                  page_request.is_a?(Hash)

      @lock.synchronize do
        start unless @started
        decode(dispatch(page_request, timeout))
      end
    end

    def close
      @lock.synchronize do
        return if @closed

        @closed = true
        begin
          close_tab if @handle
        rescue StandardError
          nil
        end
        shutdown_process
      end
    end

    private

    def dispatch(page_request, timeout)
      op = (page_request["op"] || page_request[:op]).to_s
      result = run(page_request, timeout)
      return result unless result == MISSING

      # The document was replaced, so the installed runtime went with it. Reinstalling is a read, but
      # re-dispatching a mutation is not: an act whose runtime vanished is reported as a lost epoch and
      # left for the session to resolve by reading it back.
      install_runtime(timeout)
      return JSON.generate({ status: "epoch_lost" }) unless READ_ONLY.include?(op)

      result = run(page_request, timeout)
      raise BridgeError, "The page runtime would not install" if result == MISSING

      result
    end

    # The runtime is installed once per document; every later call ships only the request.
    def run(page_request, timeout)
      expression = "return window.__wrangleRun ? window.__wrangleRun(#{JSON.generate(page_request)}) " \
                   ": #{JSON.generate(MISSING)}"
      text = tool("evaluate_javascript", { expression: expression }, timeout)
      parse_json(text, "page runtime")
    end

    def install_runtime(timeout)
      snapshot = File.read(File.join(SCRIPTS, "snapshot.js"))
      page = File.read(File.join(SCRIPTS, "page.js"))
      # snapshot.js opens with comments, so it is parenthesised: `return` followed by a comment and a
      # newline is `return;` under automatic semicolon insertion, which silently yields null.
      expression = <<~JS
        window.__wrangleSnapshot = () => (
        #{snapshot}
        );
        window.__wranglePage = (#{page});
        window.__wrangleRun = (request) => window.__wranglePage(request, window.__wrangleSnapshot);
        return "installed";
      JS
      tool("evaluate_javascript", { expression: expression }, timeout)
    end

    def decode(result)
      decoded = begin
        JSON.parse(result)
      rescue JSON::ParserError
        raise BridgeError, "The page returned invalid JSON"
      end
      raise BridgeError, "The page returned an invalid result" unless decoded.is_a?(Hash) &&
                                                                      decoded["status"].is_a?(String)

      decoded
    end

    def open_tab(params, timeout)
      url = params[:url] || params["url"]
      raise BridgeCallError.new("usage", "The MCP backend needs a URL to open") unless url.is_a?(String)

      if params[:display] || params[:bounds]
        raise BridgeCallError.new("unsupported", "The MCP backend places its own automation tab and " \
                                                 "cannot honour --display; use the default backend.")
      end

      tool("navigate_to_url", { url: url }, timeout || @startup_timeout)
      current = tabs.first || {}
      @handle = current["handle"]
      install_runtime(timeout)
      { "window_id" => 1, "tab_index" => 1, "url" => current["url"] || url, "bounds" => nil }
    end

    def close_tab
      handle = @handle
      @handle = nil
      return { "closed" => false } unless handle

      tool("close_tab", { handle: handle }, 10)
      { "closed" => true }
    end

    def tabs
      listed = parse_json(tool("list_tabs", {}, 10), "tab list")
      listed.is_a?(Array) ? listed : []
    end

    def parse_json(text, what)
      JSON.parse(text.to_s)
    rescue JSON::ParserError
      raise BridgeError, "The MCP server returned an unreadable #{what}"
    end

    # One MCP tool call, unwrapped to its single text item.
    def tool(name, arguments, timeout)
      response = rpc("tools/call", { name: name, arguments: arguments }, timeout || @request_timeout)
      content = response.dig("result", "content")
      if response.dig("result", "isError") || !content.is_a?(Array)
        raise BridgeCallError.new("tool_error", "Safari's #{name} tool failed: #{summarise(response)}")
      end

      item = content.first
      raise BridgeError, "Safari's #{name} tool returned no text" unless item.is_a?(Hash) &&
                                                                         item["text"].is_a?(String)

      item["text"]
    end

    def summarise(response)
      text = response.dig("result", "content", 0, "text") || response.dig("error", "message")
      text.to_s[0, 200]
    end

    def rpc(method, params, timeout)
      id = @next_id
      @next_id += 1
      write(JSON.generate({ jsonrpc: "2.0", id: id, method: method, params: params }))
      response = receive(id, timeout)
      if (error = response["error"])
        raise BridgeCallError.new("mcp_error", "The MCP server refused #{method}: #{error["message"]}")
      end

      response
    end

    def notify(method, params = {})
      write(JSON.generate({ jsonrpc: "2.0", method: method, params: params }))
    end

    def write(line)
      raise BridgeError, "The MCP bridge is no longer accepting requests" unless running?

      @io.write("#{line}\n")
      @io.flush
    rescue Errno::EPIPE, IOError
      raise BridgeError, "The MCP bridge is no longer accepting requests"
    end

    # Replies are read until the matching id arrives; notifications from the server are discarded.
    def receive(id, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise BridgeError, "The MCP server did not reply in time" if remaining <= 0

        line = begin
          Timeout.timeout(remaining) { @io.gets }
        rescue Timeout::Error
          raise BridgeError, "The MCP server did not reply in time"
        end
        raise BridgeError, "The MCP server closed the connection" if line.nil?

        message = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        return message if message.is_a?(Hash) && message["id"] == id
      end
    end

    def spawn_process
      @stderr_read, stderr_write = IO.pipe
      @io = IO.popen(@command, "r+", err: stderr_write)
      stderr_write.close
      @stderr_thread = Thread.new do
        while (line = @stderr_read.gets)
          @stderr.shift if @stderr.length >= 50
          @stderr << line.chomp
        end
      rescue IOError
        nil
      end
    rescue Errno::ENOENT
      raise BridgeError, "safaridriver is not available; the MCP backend needs Safari 27 or newer"
    end

    def shutdown_process
      @io&.close
    rescue IOError
      nil
    ensure
      begin
        @stderr_read&.close
      rescue IOError
        nil
      end
      @stderr_thread&.kill
      @io = nil
    end
  end
end
