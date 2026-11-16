require "openssl"
require "socket"
require "timeout"

# Reads the certificate a domain serves on 443: only its expiry and issuer. Doesn't verify the
# chain (an expired or misissued certificate is exactly what we want to read, not refuse), and
# sends SNI so kamal-proxy answers with the right one.
module CertificateProbe
  TIMEOUT = 5
  Result = Data.define(:not_after, :issuer, :error)

  # connector: ->(host, port) { OpenSSL::X509::Certificate } (tests pass a canned one).
  mattr_accessor :connector

  module_function

  def call(host, port: 443)
    certificate = (connector || method(:fetch)).call(host, port)
    Result.new(not_after: certificate.not_after, issuer: issuer_name(certificate), error: nil)
  rescue StandardError => e
    Result.new(not_after: nil, issuer: nil, error: "#{e.class}: #{e.message}".truncate(500))
  end

  def fetch(host, port)
    Timeout.timeout(TIMEOUT) do
      tcp = Socket.tcp(host, port, connect_timeout: TIMEOUT)
      context = OpenSSL::SSL::SSLContext.new
      context.verify_mode = OpenSSL::SSL::VERIFY_NONE
      ssl = OpenSSL::SSL::SSLSocket.new(tcp, context)
      ssl.hostname = host
      ssl.sync_close = true
      begin
        ssl.connect
        ssl.peer_cert or raise OpenSSL::SSL::SSLError, "no certificate"
      ensure
        ssl.close
      end
    end
  end

  # "Let's Encrypt R11" rather than the whole distinguished name.
  def issuer_name(certificate)
    parts = certificate.issuer.to_a.to_h { |name, value, _| [ name, value ] }
    [ parts["O"], parts["CN"] ].compact.uniq.join(" ").presence || certificate.issuer.to_s
  end
end
