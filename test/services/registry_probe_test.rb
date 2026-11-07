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
end
