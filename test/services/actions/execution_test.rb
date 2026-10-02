require "test_helper"

# The three action classes above previously had only cli_args and were never executed against a real
# host. What's asserted here is that [the audit is closed out correctly], not that [the command
# succeeds] -- the fake host has no real Kamal deployment, so `kamal app stop` ending with a
# non-zero status is expected.
class Actions::ExecutionTest < ExecutionLayerTest
  def build_app
    yaml = <<~YAML
      service: blog
      image: busybox:latest
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
    ManagedApp.create!(name: app_name, config_yaml: yaml,
                       destination: "production",
                       ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key,
                                                       name: "#{app_name} 的 SSH 私钥"))
  end

  def admin
    @admin ||= User.create!(email_address: "op@example.com", password: "secret123456",
                               role: "admin")
  end

  test "stop runs against the real host and writes the result to the audit" do
    app = build_app
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")

    log = AuditLog.start!(user: admin, managed_app: app, action_name: "stop",
                          target_version: nil, hosts: app.cached_app_hosts)
    RunActionJob.perform_now(log.id)

    assert_includes %w[success failure], log.reload.result
    refute_equal "pending", log.result, "The audit must be updated after execution and not stay pending"
    assert_predicate log.duration_ms, :present?
    assert_match(/\Akamal app stop\b/, log.command)
    # Proves it really reached the remote rather than exiting early locally: kamal's SSHKit output
    # includes the hostname
    assert_match "127.0.0.1", log.output_digest
  end

  test "does not execute when the lock is held and says so in the audit" do
    app = build_app
    lock_dir = ".kamal/lock-blog-production"
    FakeHost.ssh("node-1", "mkdir -p #{lock_dir} && printf 'Locked by: ci' | base64 > #{lock_dir}/details")

    log = AuditLog.start!(user: admin, managed_app: app, action_name: "restart",
                          target_version: nil, hosts: app.cached_app_hosts)
    RunActionJob.perform_now(log.id)

    assert_equal "failure", log.reload.result
    assert_match "部署进行中", log.output_digest
  ensure
    FakeHost.ssh("node-1", "rm -rf .kamal/lock-blog-production")
  end
end
