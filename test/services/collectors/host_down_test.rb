require "test_helper"

class Collectors::HostDownTest < ExecutionLayerTest
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
        port: #{FakeHost::NODES.fetch("node-2")}
    YAML

    app_name = "blog-#{SecureRandom.hex(4)}"
    ManagedApp.create!(
      name: app_name, config_yaml: yaml, destination: "production",
      ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key,
                                      name: "#{app_name} 的 SSH 私钥")
    )
  end

  teardown do
    # Use `down` + `up -d` rather than the brief's original `stop` + `start`: this fixture runs on
    # top of dind, and after `stop` sends SIGTERM the inner containerd occasionally gets stuck in a
    # half-dead state; the following `start` then fails intermittently locally and consistently in
    # CI -- once it fails, this broken container drags down every test after it (Task 2 already
    # stepped on this). `down` deletes the container entirely and `up -d` recreates it, so it
    # doesn't inherit that half-dead state.
    #
    # Readiness checking doesn't use FakeHost.ready? either -- that method memoizes "everything
    # succeeded once" as a permanent true, and calling it while the node restarts just returns the
    # cached true immediately, which can't tell at all whether node-2 has really recovered. Here we
    # use the non-memoized #wait_until_node_ready! to probe node-2 itself directly.
    system("docker compose -f docker-compose.test.yml down node-2 >/dev/null 2>&1")
    system("docker compose -f docker-compose.test.yml up -d node-2 >/dev/null 2>&1")
    FakeHost.wait_until_node_ready!("node-2", timeout: 60)
  end

  test "after a host goes down: records unreachable and keeps the last known state (including data age)" do
    FakeHost.seed_container(node: "node-2", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")

    app = build_app
    Collectors::ContainerCollector.call(app)

    assert_equal "aaaaaaa", ManagedAppStatus.new(app).versions.first

    # Remember the real observed_at of the first (reachable) observation -- below it is compared
    # second by second against the "time of the last state" reported by last_known_rows after the
    # host goes down, rather than only asserting "has a value". This timestamp preserves the
    # information "when this machine was still alive"; if "keep last known state" kept only the
    # version and lost this time, the operator still couldn't judge how old this data is now --
    # which is also a way of the "panel going blind".
    last_good_observed_at = Observation.latest_for(app).first.observed_at

    # Fault injection: tear the machine down entirely (preserving the fact on the data side: before
    # this the container collection really could connect and now really can't, it isn't simulated).
    system("docker compose -f docker-compose.test.yml down node-2 >/dev/null 2>&1")

    Collectors::ContainerCollector.call(app)

    status = ManagedAppStatus.new(app)
    row = status.last_known_rows.first

    assert_equal :unreachable, status.level
    assert_equal "aaaaaaa", row[:version],
      "the last known state must be kept after losing contact, not cleared -- otherwise 'the service is down' cannot be told apart from 'the panel is blind'"
    assert_equal last_good_observed_at.to_i, row[:stale_since].to_i,
      "the last known state must be kept together with its real age -- keeping only the version and dropping " \
      "when that state was observed leaves the operator unable to tell how stale the data is"
  end
end
