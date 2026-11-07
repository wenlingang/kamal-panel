require "test_helper"
require "shellwords"

class Collectors::ContainerCollectorTest < ExecutionLayerTest
  def build_app(hosts:)
    yaml = <<~YAML
      service: blog
      image: example/blog
      servers:
        web:
      #{hosts.map { |h| "      - #{h}" }.join("\n")}
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
      name: app_name, config_yaml: yaml, destination: "production",
      ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key,
                                      name: "#{app_name} 的 SSH 私钥")
    )
  end

  test "collects running containers and parses their version and role" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")

    app = build_app(hosts: [ "127.0.0.1" ])
    Collectors::ContainerCollector.call(app)

    observation = Observation.latest_for(app).first

    assert_equal "aaaaaaa", observation.version
    assert_equal "web", observation.role
    assert_equal "blog-web-production-aaaaaaa", observation.container_name
    assert_equal "running", observation.docker_status
    assert observation.reachable
  end
end
