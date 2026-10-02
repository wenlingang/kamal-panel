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

  test "采集到运行中的容器，并解析出版本与角色" do
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

  test "已停止的旧版本容器也被采集到——这就是回滚候选" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "0000000",
                            state: :stopped)

    app = build_app(hosts: [ "127.0.0.1" ])
    Collectors::ContainerCollector.call(app)

    by_version = Observation.latest_for(app).index_by(&:version)

    assert_equal "running", by_version["aaaaaaa"].docker_status
    assert_equal "exited",  by_version["0000000"].docker_status
  end

  test "只采集本应用的容器，不串到别的 service" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")
    FakeHost.seed_container(node: "node-1", service: "shop", role: "web",
                            destination: "production", version: "bbbbbbb")

    app = build_app(hosts: [ "127.0.0.1" ])
    Collectors::ContainerCollector.call(app)

    versions = Observation.latest_for(app).pluck(:version)

    assert_equal [ "aaaaaaa" ], versions
  end

  test "主机连不上时写一条 unreachable 记录，而不是什么都不写" do
    app = build_app(hosts: [ "192.0.2.1" ])
    Collectors::ContainerCollector.call(app)

    observation = Observation.latest_for(app).first

    refute observation.reachable
    assert_predicate observation.error, :present?
  end

  test "主机可达但一个容器都没有时，也留一条痕迹" do
    app = build_app(hosts: [ "127.0.0.1" ])
    Collectors::ContainerCollector.call(app)

    observation = Observation.latest_for(app).first

    assert observation.reachable
    assert_nil observation.container_name
    assert_nil observation.docker_status
    assert_nil observation.version
  end

  # review 发现的真实场景：docker ps 的 `.Labels` 字段会把一个容器全部
  # label 压平成一条逗号拼接的 "k=v,k=v,..." 字符串。旧实现天真地按 ","
  # 再按 "=" 切分这条字符串——哪怕 role/destination 自己没有逗号，只要
  # 容器上还挂着*别的*、值里带逗号的 label（accessory、compose、健康
  # 检查分组……这些都可能长这样），旧实现切分时就会把那条 label 拆成
  # 一段没有 "=" 的碎片，整个 parse_labels 直接抛异常，被 rescue 吞掉、
  # 退化成空 hash——role 变成 nil，version 的前缀算漏了 role/destination，
  # 静默算出一个错误的版本号。这比崩溃更糟：面板会在事故现场显示错误
  # 的 role/version，而不是报错。新实现改用 docker 自己的 `.Label` 函数
  # 按字段单独 JSON 编码取值，不再依赖对这条压平字符串做切分，天然不
  # 受这类"某个不相关的 label 里带逗号"的影响。
  test "容器身上其它 label 的值里带逗号，也不会污染 role/version 的解析" do
    name = "blog-web-production-aaaaaaa"

    FakeHost.ssh("node-1", <<~SH)
      docker run -d --name #{Shellwords.escape(name)} \
        --label service=blog \
        --label destination=production \
        --label role=web \
        --label kamal.deploy_group=#{Shellwords.escape('frontend,canary')} \
        busybox:latest sleep 3600
    SH

    app = build_app(hosts: [ "127.0.0.1" ])
    Collectors::ContainerCollector.call(app)

    observation = Observation.latest_for(app).first

    assert_equal "web", observation.role
    assert_equal "aaaaaaa", observation.version
    assert_equal "running", observation.docker_status
  end

  test "docker ps 输出里有一行解析不了时，跳过它并记录日志，而不是悄悄丢掉" do
    app = build_app(hosts: [ "127.0.0.1" ])

    fake_session = Object.new
    fake_session.define_singleton_method(:capture_many) do |hosts|
      hosts.index_with { |h| Collectors::SshSession::Result.new(host: h, stdout: "not-json\n", error: nil) }
    end

    original_new = Collectors::SshSession.method(:new)
    Collectors::SshSession.define_singleton_method(:new) { |*_args| fake_session }

    log_output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = Logger.new(log_output)

    count = Collectors::ContainerCollector.call(app)

    # 全部行解析失败必须留下一行痕迹，而不是零行——零行会让上一轮的旧观测
    # 继续以"最新"的身份被渲染成当前状态（见 final review I1）。
    assert_equal 1, count

    observation = Observation.latest_for(app).first
    refute observation.reachable, "解析不了不能悄悄算作\"可达且一切正常\""
    assert_match(/无法解析/, observation.error)
    refute_match(/not-json/, observation.error.to_s,
      "落库的 error 摘要不应包含原始行内容")

    logged = log_output.string
    assert_match(/无法解析 docker ps 输出/, logged)
    assert_match(/JSON::ParserError/, logged)
    assert_match(/127\.0\.0\.1/, logged)
    refute_match(/not-json/, logged, "不应该把原始行内容（或衍生出的错误摘录）记进日志")
  ensure
    Collectors::SshSession.define_singleton_method(:new, original_new)
    Rails.logger = original_logger
  end
end
