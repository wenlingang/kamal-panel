require "test_helper"

class RegistryProbeTest < ActiveSupport::TestCase
  MANIFEST = "https://registry.example.com/v2/example/blog/manifests/abc1234".freeze

  setup do
    Rails.cache.clear
    # simple_deploy.yml: registry.example.com, image example/blog, username "someone".
    @managed_app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                                      destination: "production")
  end

  def with_credential(server: "registry.example.com")
    @managed_app.update!(registry_credential: RegistryCredential.create!(name: "reg", value: "s3cret", server:))
  end

  test "an anonymous 200 means present; the request asks for every manifest kind" do
    stub_http("HEAD #{MANIFEST}" => [ 200 ]) do |calls|
      assert_equal :present, RegistryProbe.new(@managed_app).status("abc1234")

      accept = calls.sole[:headers]["accept"]
      assert_includes accept, "application/vnd.oci.image.index.v1+json"
      assert_includes accept, "application/vnd.docker.distribution.manifest.v2+json"
    end
  end

  test "follows a Bearer challenge, sending the registry credential to the token service" do
    with_credential
    challenge = 'Bearer realm="https://auth.example.com/token",service="registry.example.com",' \
                'scope="repository:example/blog:pull"'

    stub_http(
      "HEAD #{MANIFEST}" => ->(request) {
        request["Authorization"] == "Bearer tok-123" ? [ 404 ] : [ 401, nil, { "WWW-Authenticate" => challenge } ]
      },
      "GET https://auth.example.com/token?scope=repository%3Aexample%2Fblog%3Apull&service=registry.example.com" =>
        ->(request) {
          expected = "Basic #{Base64.strict_encode64('someone:s3cret')}"
          request["Authorization"] == expected ? [ 200, { token: "tok-123" } ] : [ 401, {} ]
        }
    ) do |calls|
      assert_equal :missing, RegistryProbe.new(@managed_app).status("abc1234")
      assert_equal 3, calls.size
    end
  end

  test "accepts access_token too (some token services use that name)" do
    stub_http(
      "HEAD #{MANIFEST}" => ->(request) {
        request["Authorization"] ? [ 200 ] : [ 401, nil, { "WWW-Authenticate" => 'Bearer realm="https://auth.example.com/token"' } ]
      },
      "GET https://auth.example.com/token" => [ 200, { access_token: "tok" } ]
    ) do
      assert_equal :present, RegistryProbe.new(@managed_app).status("abc1234")
    end
  end

  test "answers a Basic challenge with the credential" do
    with_credential
    stub_http(
      "HEAD #{MANIFEST}" => ->(request) {
        request["Authorization"]&.start_with?("Basic ") ? [ 200 ] : [ 401, nil, { "WWW-Authenticate" => 'Basic realm="reg"' } ]
      }
    ) do
      assert_equal :present, RegistryProbe.new(@managed_app).status("abc1234")
    end
  end

  test "a challenge it can't meet is unknown, not missing" do
    stub_http("HEAD #{MANIFEST}" => [ 401, nil, { "WWW-Authenticate" => 'Basic realm="reg"' } ]) do
      assert_equal :unknown, RegistryProbe.new(@managed_app).status("abc1234")
    end
  end

  test "network errors and odd answers are unknown, and unknown isn't cached" do
    stub_http("HEAD #{MANIFEST}" => Errno::ECONNREFUSED) do
      assert_equal :unknown, RegistryProbe.new(@managed_app).status("abc1234")
    end
    stub_http("HEAD #{MANIFEST}" => [ 200 ]) do
      assert_equal :present, RegistryProbe.new(@managed_app).status("abc1234")
    end
  end

  test "a definite answer is cached" do
    stub_http("HEAD #{MANIFEST}" => [ 404 ]) do |calls|
      probe = RegistryProbe.new(@managed_app)
      2.times { assert_equal :missing, probe.status("abc1234") }
      assert_equal 1, calls.size
    end
  end

  test "never sends the credential to a registry other than the one it was registered for" do
    [ nil, "evil.example.net" ].each do |server|
      Rails.cache.clear
      RegistryCredential.where(name: "reg").each { |c| @managed_app.update!(registry_credential: nil); c.destroy }
      with_credential(server:)

      stub_http("HEAD #{MANIFEST}" => [ 401, { "www-authenticate" => 'Basic realm="registry"' } ]) do |calls|
        assert_equal :unknown, RegistryProbe.new(@managed_app).status("abc1234")
        assert calls.none? { |call| call[:headers]["authorization"] }, "credential leaked for server=#{server.inspect}"
      end
    end
  end

  test "Docker Hub: no registry server means registry-1.docker.io, and bare images get library/" do
    yaml = file_fixture("simple_deploy.yml").read.sub("  server: registry.example.com\n", "").sub("image: example/blog", "image: blog")
    @managed_app.update!(config_yaml: yaml)

    probe = RegistryProbe.new(@managed_app)
    assert_equal "registry-1.docker.io", probe.host
    assert_equal "library/blog", probe.image

    stub_http("HEAD https://registry-1.docker.io/v2/library/blog/manifests/v1" => [ 200 ]) do
      assert_equal :present, probe.status("v1")
    end
  end
end
