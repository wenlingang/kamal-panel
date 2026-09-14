require "test_helper"

class KamalLockTest < ExecutionLayerTest
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

    app_name = "blog-#{SecureRandom.hex(4)}"
    ManagedApp.create!(name: app_name, config_yaml: yaml,
                       destination: "production",
                       ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key,
                                                       name: "#{app_name} 的 SSH 私钥"))
  end

  test "没有锁时报告未锁定" do
    status = KamalLock.new(build_app).status

    refute status[:locked]
    assert_nil status[:error]
  end

  test "锁目录存在时报告已锁定并带出持有者信息" do
    app = build_app
    lock_dir = ".kamal/lock-blog-production"
    FakeHost.ssh("node-1", "mkdir -p #{lock_dir} && printf 'Locked by: ci@example.com' | base64 > #{lock_dir}/details")

    status = KamalLock.new(app).status

    assert status[:locked]
    assert_match "ci@example.com", status[:details]
  ensure
    FakeHost.ssh("node-1", "rm -rf .kamal/lock-blog-production")
  end

  test "锁消息里恰好含有哨兵字符串时仍报告已锁定（Critical 1，task-5 review）" do
    # 锁的 details 是持有锁的人写的自由文本（write_lock_details 里的
    # message 参数，来自 `kamal lock acquire -m`），面板对它的内容没有
    # 任何控制。旧实现用 `stdout.include?("LOCK_ABSENT")` 判断"是否已
    # 解锁"，而这个子串恰恰可能出现在这段自由文本里——一条锁消息只要
    # 提到 "LOCK_ABSENT" 这几个字符（哪怕只是在讨论这个哨兵值本身），
    # 旧实现就会把"有锁"误判成"未锁定"。这条测试用一段真实包含该
    # 子串、但仍然是"有锁"状态的 details，锁定新实现（只看第一行的
    # 判定标记，不看 payload 内容）不会重蹈覆辙。
    app = build_app
    lock_dir = ".kamal/lock-blog-production"
    message = "Locked by: ci@example.com — investigating why LOCK_ABSENT never showed up in the logs"
    FakeHost.ssh("node-1", "mkdir -p #{lock_dir} && printf #{Shellwords.escape(message)} | base64 > #{lock_dir}/details")

    status = KamalLock.new(app).status

    assert status[:locked],
      "锁消息里含有 \"LOCK_ABSENT\" 子串不该被误判成「未锁定」——判定信号不能和自由文本共用同一个通道"
    assert_match "ci@example.com", status[:details]
  ensure
    FakeHost.ssh("node-1", "rm -rf .kamal/lock-blog-production")
  end

  test "主机不可达时报告错误而不是「未锁定」" do
    app = build_app
    app.update_column(:config_yaml, app.config_yaml.sub("127.0.0.1", "192.0.2.1"))

    status = KamalLock.new(app.reload).status

    refute status[:locked]
    assert_predicate status[:error], :present?
  end
end
