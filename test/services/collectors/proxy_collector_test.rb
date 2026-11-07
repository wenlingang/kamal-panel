require "test_helper"

class Collectors::ProxyCollectorTest < ExecutionLayerTest
  setup do
    FakeHost.start_proxy("node-1")
  end

  def build_app(destination: "production")
    yaml = <<~YAML
      service: blog
      image: example/blog
      servers:
        web:
          - 127.0.0.1
      registry:
        server: registry.example.com
        username: someone
        password:
          - KAMAL_REGISTRY_PASSWORD
      builder:
        arch: amd64
      ssh:
        user: deploy
        port: #{FakeHost::NODES.fetch("node-1")}
    YAML

    app_name = "blog-#{SecureRandom.hex(4)}"
    ManagedApp.create!(
      name: app_name, config_yaml: yaml, destination: destination,
      ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key,
                                      name: "#{app_name} 的 SSH 私钥")
    )
  end

  test "collects deployed route targets" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")
    FakeHost.proxy_deploy(node: "node-1", service: "blog-web-production",
                          target: "blog-web-production-aaaaaaa:80")

    app = build_app
    Collectors::ProxyCollector.call(app)

    target = ProxyTarget.where(managed_app: app).order(:id).last

    assert_equal "blog-web-production", target.service_name
    assert_match(/blog-web-production-aaaaaaa/, target.target)
    assert target.reachable
    assert_predicate target.raw, :present?
  end

  private
    def with_stubbed_stdout(app, stdout)
      fake_session = Object.new
      fake_session.define_singleton_method(:capture_many) do |hosts|
        hosts.index_with { |h| Collectors::SshSession::Result.new(host: h, stdout: stdout, error: nil) }
      end

      original_new = Collectors::SshSession.method(:new)
      Collectors::SshSession.define_singleton_method(:new) { |*_args| fake_session }

      yield
    ensure
      Collectors::SshSession.define_singleton_method(:new, original_new)
    end
end
