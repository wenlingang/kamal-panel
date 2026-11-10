require "openssl"
require "socket"

# A one-route HTTPS server on 127.0.0.1 with a self-signed certificate, for checking that a
# connection's CA certificate is really what makes TLS verification pass (the HttpStub adapter
# skips TLS altogether). Answers every request with {"username":"me"}.
module TlsTestServer
  module_function

  def key = @key ||= OpenSSL::PKey::RSA.new(2048)

  def certificate
    @certificate ||= begin
      name = OpenSSL::X509::Name.parse("/CN=127.0.0.1")
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = cert.issuer = name
      cert.public_key = key.public_key
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + 3600
      extensions = OpenSSL::X509::ExtensionFactory.new(cert, cert)
      cert.add_extension(extensions.create_extension("basicConstraints", "CA:TRUE", true))
      cert.add_extension(extensions.create_extension("subjectAltName", "IP:127.0.0.1"))
      cert.sign(key, OpenSSL::Digest.new("SHA256"))
      cert
    end
  end

  # Yields the server's base URL; the server lives for the block.
  def run
    tcp = TCPServer.new("127.0.0.1", 0)
    context = OpenSSL::SSL::SSLContext.new
    context.cert = certificate
    context.key = key
    server = OpenSSL::SSL::SSLServer.new(tcp, context)

    thread = Thread.new do
      loop do
        socket = server.accept
        Thread.new(socket) { |client| answer(client) }
      rescue OpenSSL::SSL::SSLError, IOError, SystemCallError
        next # a client that rejected the certificate
      end
    end
    yield "https://127.0.0.1:#{tcp.addr[1]}"
  ensure
    thread&.kill
    server&.close
  end

  def answer(client)
    while (line = client.gets) && line != "\r\n"; end
    body = '{"username":"me"}'
    client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
  ensure
    client.close
  end
end
