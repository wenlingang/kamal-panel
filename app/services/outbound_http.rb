require "net/http"

# The one place the panel talks HTTP to the outside world (Git platforms, image registries, alert
# notification webhooks).
# Everything goes through .request so timeouts are never forgotten, and so tests can swap the
# adapter for a canned one instead of reaching the network (no WebMock in this repo).
module OutboundHttp
  TIMEOUT = 5 # seconds, both open and read: a slow platform must not hold a page hostage

  # Network-level failures, folded into one class so callers rescue one thing.
  class Error < StandardError; end
  # The certificate couldn't be verified: worth telling apart, since the fix (trust a CA) differs.
  class TlsError < Error; end

  NETWORK_ERRORS = [
    Timeout::Error, SocketError, SystemCallError, IOError, EOFError, OpenSSL::SSL::SSLError,
    Net::HTTPBadResponse, Net::ProtocolError
  ].freeze

  # adapter: ->(uri, request, timeout) { Net::HTTPResponse }
  mattr_accessor :adapter

  module_function

  # verb: :get, :head or :post (body: a String, for notification webhooks). Returns the
  # Net::HTTPResponse whatever its status; deciding what a 404 means is the caller's business.
  # ca_certificate: PEM (one or more certificates) trusted for this request on top of the system
  # store, for self-hosted servers behind a private CA.
  def request(verb, url, headers: {}, body: nil, timeout: TIMEOUT, ca_certificate: nil)
    uri = URI.parse(url)
    raise Error, "unsupported URL scheme: #{uri.scheme.inspect}" unless %w[http https].include?(uri.scheme)

    request = Net::HTTP.const_get(verb.to_s.capitalize).new(uri, headers.merge("User-Agent" => "kamal-panel"))
    request.body = body unless body.nil?
    if adapter
      adapter.call(uri, request, timeout)
    else
      perform(uri, request, timeout, cert_store: cert_store(ca_certificate))
    end
  rescue URI::InvalidURIError => e
    raise Error, e.message
  rescue OpenSSL::SSL::SSLError => e
    raise TlsError, "#{e.class}: #{e.message}"
  rescue *NETWORK_ERRORS => e
    raise Error, "#{e.class}: #{e.message}"
  end

  def perform(uri, request, timeout, cert_store: nil)
    options = { use_ssl: uri.scheme == "https", open_timeout: timeout, read_timeout: timeout,
                ssl_timeout: timeout }
    options[:cert_store] = cert_store if cert_store
    Net::HTTP.start(uri.host, uri.port, **options) { |http| http.request(request) }
  end

  # nil without extra certificates, so Net::HTTP keeps its own default store.
  def cert_store(pem)
    certificates = parse_certificates(pem)
    return if certificates.empty?

    store = OpenSSL::X509::Store.new
    store.set_default_paths
    certificates.each { |certificate| store.add_cert(certificate) }
    store
  end

  # Every certificate in a PEM bundle. Raises OpenSSL::X509::CertificateError on garbage.
  def parse_certificates(pem)
    blocks = pem.to_s.scan(/-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m)
    raise OpenSSL::X509::CertificateError, "no certificate found" if blocks.empty? && pem.present?

    blocks.map { |block| OpenSSL::X509::Certificate.new(block) }
  end

  # Runs the block over items on a few threads. Used where a page needs one remote answer per row
  # (CI status, image presence): sequential calls would add up to seconds, and per-row frames would
  # tie up one server thread per row instead. Exceptions are returned in place, not raised, so one
  # bad row can't sink the others. The thread pool itself lives in ParallelMap, shared with the log
  # query (one SSH session per host).
  def parallel_map(items, threads: 8, &block)
    ParallelMap.call(items, threads:, &block)
  end
end
