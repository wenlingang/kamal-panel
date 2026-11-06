require "test_helper"

# The real command over real SSH, against a dind fake host: docker stats' actual output format and
# the /proc files of a Linux box.
class Collectors::MetricsCollectorIntegrationTest < ExecutionLayerTest
  def build_app
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

    name = "blog-#{SecureRandom.hex(4)}"
    ManagedApp.create!(name:, config_yaml: yaml, destination: "production",
                       ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key, name: "#{name} key"))
  end

  test "collects the app's running container and the host's load, memory and disk" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web", destination: "production", version: "aaaaaaa")
    FakeHost.seed_container(node: "node-1", service: "shop", role: "web", destination: "production", version: "bbbbbbb")
    app = build_app

    CollectMetricsJob.perform_now(app)

    metric = ContainerMetric.where(managed_app: app).sole
    assert_equal [ "blog-web-production-aaaaaaa", "web", "app", "aaaaaaa" ],
                 [ metric.container_name, metric.source, metric.kind, metric.version ]
    assert_operator metric.mem_bytes, :>, 0
    assert_not_nil metric.cpu_percent
    assert_equal 1, metric.pids

    host = HostMetric.find_by!(host: "127.0.0.1")
    assert_operator host.cpus, :>=, 1
    assert_operator host.mem_total_bytes, :>, host.mem_available_bytes
    assert_operator host.disk_total_bytes, :>, host.disk_used_bytes
    assert_not_nil host.load1
  end

  test "an unreachable host records nothing and does not raise" do
    app = build_app
    app.update!(config_yaml: app.config_yaml.sub("127.0.0.1", "192.0.2.1"))

    Collectors::MetricsCollector.new(app, ssh: Collectors::SshSession.new(app, connect_timeout: 1)).call

    assert_equal 0, ContainerMetric.count
    assert_equal 0, HostMetric.count
  end
end
