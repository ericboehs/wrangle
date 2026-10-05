# frozen_string_literal: true

require "json"

module Wrangle
  # Socket accept loop and JSON dispatch for one desktop session.
  module DesktopSessionProtocol
    private

    def serve(server, deadline: nil)
      @serving = true
      File.chmod(0o600, @socket_path)
      loop do
        break if deadline && !socket_ready?(server, deadline)

        client = server.accept
        line = client.gets
        next client.close unless line

        request = parse(line)
        client.puts(JSON.generate(dispatch(request)))
        client.close
        break if request["op"] == "close" || @approval_resolved
      end
    ensure
      @serving = false
      server.close
    end

    def socket_ready?(server, deadline)
      remaining = deadline - monotonic
      remaining.positive? && server.wait_readable(remaining)
    end

    def parse(line)
      JSON.parse(line)
    rescue JSON::ParserError
      { "op" => "bad" }
    end

    def dispatch(request)
      { "ok" => true, "value" => handle(request) }
    rescue Wrangle::Error => e
      terminal = e.is_a?(ScopeLost) || e.is_a?(DeliveryUnknown) || e.is_a?(DriverUnavailable) ||
                 (e.is_a?(DriverRefusal) && e.delivery_unknown?)
      log_refusal(request, e)
      refusal(e.class.name.split("::").last, e.message, terminal:)
    rescue ArgumentError => e
      log_refusal(request, e)
      refusal("ArgumentError", e.message, terminal: false)
    rescue StandardError => e
      log_refusal(request, e)
      refusal(e.class.name, "internal error: #{e.message} (#{e.backtrace&.first})", terminal: true)
    end
  end
end
