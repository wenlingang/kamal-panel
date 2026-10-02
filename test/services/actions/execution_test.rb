require "test_helper"

# 前面三个动作类此前只有 cli_args，从未对真实主机执行过。
# 这里断言的是【审计被正确收尾】，不是【命令成功】——fake host 上
# 没有真实的 Kamal 部署，`kamal app stop` 以非零状态结束是预期的。
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

  test "stop 对真实主机执行并把结果写进审计" do
    app = build_app
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")

    log = AuditLog.start!(user: admin, managed_app: app, action_name: "stop",
                          target_version: nil, hosts: app.cached_app_hosts)
    RunActionJob.perform_now(log.id)

    assert_includes %w[success failure], log.reload.result
    refute_equal "pending", log.result, "执行完必须更新审计，不能停在 pending"
    assert_predicate log.duration_ms, :present?
    assert_match(/\Akamal app stop\b/, log.command)
    # 证明真的走到了远端而不是在本地早退：kamal 的 SSHKit 输出会带上主机名
    assert_match "127.0.0.1", log.output_digest
  end

  test "锁被占用时不执行，并在审计中说明" do
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
