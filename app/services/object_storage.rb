require "openssl"

# Just enough of the S3 API for backups: put a file, delete it, and hand out a short-lived download
# link. Signed with AWS Signature Version 4, which every S3-compatible store speaks (AWS S3,
# Cloudflare R2, MinIO, Aliyun OSS, Backblaze B2...). No SDK: four requests don't justify one, and
# going through OutboundHttp keeps the timeouts and the test seam the rest of the panel uses.
#
# A single PUT carries up to 5 GB, which is plenty for the databases a Kamal accessory holds; a
# bigger dump fails with the store's own error rather than silently.
class ObjectStorage
  class Error < StandardError; end

  UPLOAD_TIMEOUT = 300
  EMPTY_SHA256 = Digest::SHA256.hexdigest("")

  def initialize(destination, now: -> { Time.now.utc })
    @destination = destination
    @now = now
  end

  # io: a readable IO positioned at the start; size in bytes; sha256 the hex digest of its content
  # (signed, so the store rejects a body that got corrupted on the way).
  def put(key, io, size:, sha256:, content_type: "application/octet-stream")
    response = signed(:put, key, payload_sha256: sha256,
                                 headers: { "Content-Length" => size.to_s, "Content-Type" => content_type },
                                 body_stream: io, timeout: UPLOAD_TIMEOUT)
    raise Error, failure_text(response) unless response.is_a?(Net::HTTPSuccess)
  end

  def put_string(key, string)
    response = signed(:put, key, payload_sha256: Digest::SHA256.hexdigest(string),
                                 headers: { "Content-Length" => string.bytesize.to_s }, body: string)
    raise Error, failure_text(response) unless response.is_a?(Net::HTTPSuccess)
  end

  # Deleting what isn't there is fine (S3 answers 204 either way; some stores say 404).
  def delete(key)
    response = signed(:delete, key, payload_sha256: EMPTY_SHA256)
    raise Error, failure_text(response) unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPNotFound)
  end

  # Writes and removes a small marker under the prefix: proves the endpoint, the bucket, the keys and
  # the write and delete permissions in one go, which is what a backup needs.
  def check!
    key = destination.key_for(".kamal-panel-check")
    put_string(key, "ok")
    delete(key)
  end

  # A GET link valid for expires_in seconds, signed in the query string, for the browser to fetch.
  def presigned_url(key, expires_in: 600)
    time = now.call
    uri = object_uri(key)
    query = {
      "X-Amz-Algorithm" => "AWS4-HMAC-SHA256",
      "X-Amz-Credential" => "#{destination.access_key_id}/#{scope(time)}",
      "X-Amz-Date" => amz_date(time),
      "X-Amz-Expires" => expires_in.to_s,
      "X-Amz-SignedHeaders" => "host"
    }
    canonical = [ "GET", uri.path, canonical_query(query), "host:#{host_header(uri)}\n", "host", "UNSIGNED-PAYLOAD" ].join("\n")
    signature = sign(time, canonical)
    "#{uri.scheme}://#{host_header(uri)}#{uri.path}?#{canonical_query(query)}&X-Amz-Signature=#{signature}"
  end

  # The URI an object lives at: https://endpoint/bucket/key (path style) or
  # https://bucket.endpoint/key (virtual-hosted style, what AWS prefers for new buckets).
  def object_uri(key)
    base = URI.parse(destination.endpoint.to_s.chomp("/"))
    path = key.to_s.split("/").map { |segment| uri_escape(segment) }.join("/")
    if destination.path_style?
      base.path = "#{base.path}/#{uri_escape(destination.bucket)}/#{path}"
    else
      base.host = "#{destination.bucket}.#{base.host}"
      base.path = "#{base.path}/#{path}"
    end
    base
  end

  private
    attr_reader :destination, :now

    def signed(verb, key, payload_sha256:, headers: {}, body: nil, body_stream: nil, timeout: OutboundHttp::TIMEOUT)
      time = now.call
      uri = object_uri(key)
      signed_headers = {
        "host" => host_header(uri),
        "x-amz-content-sha256" => payload_sha256,
        "x-amz-date" => amz_date(time)
      }
      names = signed_headers.keys.sort
      canonical = [
        verb.to_s.upcase, uri.path, "",
        names.map { |name| "#{name}:#{signed_headers[name]}\n" }.join,
        names.join(";"), payload_sha256
      ].join("\n")
      authorization = "AWS4-HMAC-SHA256 Credential=#{destination.access_key_id}/#{scope(time)}, " \
                      "SignedHeaders=#{names.join(';')}, Signature=#{sign(time, canonical)}"

      OutboundHttp.request(verb, uri.to_s, body:, body_stream:, timeout:,
                           headers: headers.merge(signed_headers.except("host"), "Authorization" => authorization))
    rescue OutboundHttp::Error => e
      raise Error, e.message
    end

    def sign(time, canonical_request)
      to_sign = [ "AWS4-HMAC-SHA256", amz_date(time), scope(time), Digest::SHA256.hexdigest(canonical_request) ].join("\n")
      OpenSSL::HMAC.hexdigest("SHA256", signing_key(time), to_sign)
    end

    def signing_key(time)
      key = "AWS4#{destination.secret_access_key}"
      [ time.strftime("%Y%m%d"), region, "s3", "aws4_request" ].reduce(key) do |current, part|
        OpenSSL::HMAC.digest("SHA256", current, part)
      end
    end

    def scope(time) = "#{time.strftime('%Y%m%d')}/#{region}/s3/aws4_request"
    def region = destination.region.presence || "us-east-1"
    def amz_date(time) = time.strftime("%Y%m%dT%H%M%SZ")

    # Host as sent in the Host header: with the port only when it isn't the scheme's default.
    def host_header(uri) = uri.port == uri.default_port ? uri.host : "#{uri.host}:#{uri.port}"

    def canonical_query(params)
      params.sort.map { |name, value| "#{uri_escape(name)}=#{uri_escape(value)}" }.join("&")
    end

    # RFC 3986 unreserved characters stay, everything else is percent-encoded (what SigV4 expects).
    def uri_escape(value) = value.to_s.b.gsub(/[^A-Za-z0-9\-._~]/n) { |char| format("%%%02X", char.ord) }

    # S3 errors are XML: <Code>SignatureDoesNotMatch</Code><Message>...</Message>.
    def failure_text(response)
      body = response.body.to_s
      code = body[%r{<Code>(.*?)</Code>}m, 1]
      message = body[%r{<Message>(.*?)</Message>}m, 1]
      [ "HTTP #{response.code}", code, message ].compact.join(" ").truncate(300)
    end
end
