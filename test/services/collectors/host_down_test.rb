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
    # 用 `down` + `up -d` 而不是 brief 里原本的 `stop` + `start`：这个
    # fixture 跑在 dind 之上，`stop` 发 SIGTERM 之后内层 containerd 偶尔
    # 会卡在一个半死状态，随后的 `start` 在本地是间歇性失败、在 CI 里是
    # 稳定失败——一旦失败，这个损坏的容器会一路拖垮它之后的每一个测试
    # （Task 2 已经踩过这个坑）。`down` 把容器整个删掉、`up -d` 重新创建，
    # 不会继承那个半死状态。
    #
    # 就绪判断也不用 FakeHost.ready?——那个方法把"曾经全体成功过一次"
    # 记忆化成永久 true，节点重启期间调用它只会立刻返回缓存的 true，
    # 完全测不出 node-2 有没有真的恢复。这里用不经过记忆化的
    # #wait_until_node_ready! 直接探测 node-2 本身。
    system("docker compose -f docker-compose.test.yml down node-2 >/dev/null 2>&1")
    system("docker compose -f docker-compose.test.yml up -d node-2 >/dev/null 2>&1")
    FakeHost.wait_until_node_ready!("node-2", timeout: 60)
  end

  test "机器停机后：写入 unreachable，且保留上一次已知状态（含数据年龄）" do
    FakeHost.seed_container(node: "node-2", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")

    app = build_app
    Collectors::ContainerCollector.call(app)

    assert_equal "aaaaaaa", ManagedAppStatus.new(app).versions.first

    # 记住第一次（可达）那条观测真实的 observed_at——下面要拿它跟失联
    # 之后 last_known_rows 报的"上次状态的时间"做逐秒比对，而不是只
    # 断言"有值"。这条时间戳保留了「这台机器是什么时候还活着」这条信息，
    # 「保留上次已知状态」如果只保留版本号却丢了这个时间，操作者照样
    # 没法判断这份数据现在有多旧——那也是一种「面板瞎了」。
    last_good_observed_at = Observation.latest_for(app).first.observed_at

    # 故障注入：把机器整个拆掉（保留数据这一端的事实：容器采集之前
    # 是真的连得上、现在是真的连不上，不是模拟出来的）。
    system("docker compose -f docker-compose.test.yml down node-2 >/dev/null 2>&1")

    Collectors::ContainerCollector.call(app)

    status = ManagedAppStatus.new(app)
    row = status.last_known_rows.first

    assert_equal :unreachable, status.level
    assert_equal "aaaaaaa", row[:version],
      "失联后必须保留上次已知状态，不能清空——否则无法区分「服务挂了」和「面板瞎了」"
    assert_equal last_good_observed_at.to_i, row[:stale_since].to_i,
      "保留上次已知状态必须连带它的真实年龄一起保留——只留版本号、丢掉" \
      "这是什么时候的状态，操作者照样判断不出这份数据现在有多旧"
  end
end
