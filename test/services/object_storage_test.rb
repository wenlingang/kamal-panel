require "test_helper"

class ObjectStorageTest < ActiveSupport::TestCase
  include HttpStub

  Destination = Struct.new(:endpoint, :region, :bucket, :prefix, :access_key_id, :secret_access_key, :path_style,
                           keyword_init: true) do
    def path_style? = path_style
    def key_for(rest) = [ prefix.presence, rest ].compact.join("/")
  end

  # The presigned-URL example from the AWS Signature Version 4 documentation ("Authenticating
  # Requests: Using Query Parameters"), so the signing is checked against a value AWS published.
  test "signs a download link exactly as AWS documents it" do
    destination = Destination.new(endpoint: "https://s3.amazonaws.com", region: "us-east-1", bucket: "examplebucket",
                                  access_key_id: "AKIAIOSFODNN7EXAMPLE",
                                  secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", path_style: false)
    storage = ObjectStorage.new(destination, now: -> { Time.utc(2013, 5, 24) })

    url = storage.presigned_url("test.txt", expires_in: 86_400)

    assert url.start_with?("https://examplebucket.s3.amazonaws.com/test.txt?")
    assert_includes url, "X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
  end

  test "puts with a signed body hash, path style, and reports the store's error" do
    destination = Destination.new(endpoint: "http://minio.internal:9000", region: "us-east-1", bucket: "backups",
                                  access_key_id: "key", secret_access_key: "secret", path_style: true)
    storage = ObjectStorage.new(destination)

    stub_http("PUT http://minio.internal:9000/backups/a%20b/dump.sql.gz" => [ 200, "" ],
              "DELETE http://minio.internal:9000/backups/gone" => [ 403, "<Error><Code>AccessDenied</Code><Message>no</Message></Error>" ]) do |calls|
      storage.put("a b/dump.sql.gz", StringIO.new("data"), size: 4, sha256: Digest::SHA256.hexdigest("data"))

      headers = calls.first[:headers]
      assert_equal Digest::SHA256.hexdigest("data"), headers["x-amz-content-sha256"]
      assert_match %r{\AAWS4-HMAC-SHA256 Credential=key/\d{8}/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=\h{64}\z},
                   headers["authorization"]

      error = assert_raises(ObjectStorage::Error) { storage.delete("gone") }
      assert_equal "HTTP 403 AccessDenied no", error.message
    end
  end
end
