require "test_helper"

class Actions::ForceUnlockTest < ExecutionLayerTest
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

  test "强制解锁本身不需要先拿到锁" do
    refute Actions::ForceUnlock.requires_lock?
  end

  test "强制解锁需要手输应用名" do
    assert Actions::ForceUnlock.confirm_by_name?
  end

  test "解锁后锁状态变为未锁定" do
    app = build_app
    lock_dir = ".kamal/lock-blog-production"
    FakeHost.ssh("node-1", "mkdir -p #{lock_dir} && printf 'stale' | base64 > #{lock_dir}/details")
    assert KamalLock.new(app).status[:locked]

    user = User.create!(email_address: "op@example.com", password: "secret123456", role: "admin")
    log = AuditLog.start!(user: user, managed_app: app, action_name: "force_unlock",
                          target_version: nil, hosts: app.cached_app_hosts)
    RunActionJob.perform_now(log.id)

    assert_equal "success", log.reload.result
    assert_equal "kamal lock release", log.command
    refute KamalLock.new(app).status[:locked]
  ensure
    FakeHost.ssh("node-1", "rm -rf .kamal/lock-blog-production")
  end

  test "强制解锁在审计中带独立标记" do
    app = build_app
    user = User.create!(email_address: "op2@example.com", password: "secret123456", role: "admin")
    log = AuditLog.start!(user: user, managed_app: app, action_name: "force_unlock",
                          target_version: nil, hosts: app.cached_app_hosts)

    assert_equal "force_unlock", log.action_name
  end
end
