# frozen_string_literal: true

require "socket"

# A stand-in for the TypeSafe endpoint that is a real HTTP server on a real socket.
#
# Jev is the one place Wrangle talks to a network, and the things worth testing about it are all
# things a stubbed `Net::HTTP` cannot have: a 429 that has to be retried, a body that arrives
# truncated, a connection that opens and then says nothing until the read timeout fires. Those are
# properties of the transport, so the transport is real and only the far end is fake.
class FakeTypeSafe
  attr_reader :requests

  # `script` is the list of replies to give, in order; the last one repeats. A reply is a status and
  # a body, or `:silence` for a server that accepts the connection and then never answers.
  def initialize(script)
    @script = Array(script)
    @requests = []
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { serve }
    @thread.abort_on_exception = false
  end

  def endpoint = "http://127.0.0.1:#{@server.addr[1]}/v1/systemone"

  def stop
    @thread&.kill
    @server&.close
  rescue IOError
    nil
  end

  private

  def serve
    loop do
      client = @server.accept
      handle(client)
    rescue IOError, Errno::EBADF
      break
    end
  end

  def handle(client)
    @requests << read_request(client)
    reply = @script.length > 1 ? @script.shift : @script.first
    return sleep if reply == :silence # Held open, saying nothing, until the read timeout fires.

    write_reply(client, reply)
    client.close
  end

  # Enough of HTTP/1.1 to be honest about it: headers to the blank line, then Content-Length bytes.
  def read_request(client)
    headers = {}
    request_line = client.gets
    while (line = client.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.to_s.strip
    end
    length = headers.fetch("content-length", "0").to_i
    { "request_line" => request_line.to_s.strip, "headers" => headers,
      "body" => length.positive? ? client.read(length) : "" }
  end

  def write_reply(client, reply)
    status, body = reply
    client.write("HTTP/1.1 #{status} #{status == 200 ? "OK" : "Error"}\r\n")
    client.write("Content-Type: application/json\r\n")
    client.write("Content-Length: #{body.bytesize}\r\n\r\n")
    client.write(body)
  end
end
