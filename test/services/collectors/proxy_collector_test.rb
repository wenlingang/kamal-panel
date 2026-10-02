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

  test "proxy 上没有任何路由时，采集成功且留一条可达无数据的记录" do
    app = build_app

    assert_equal 1, Collectors::ProxyCollector.call(app)

    row = ProxyTarget.where(managed_app: app).sole

    assert row.reachable
    assert_nil row.service_name
    assert_nil row.raw
    assert_nil row.error
  end

  test "采集到已部署的路由目标" do
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

  test "机器上没跑 kamal-proxy 时不报错，仍标记为可达，且与「跑着但空路由表」区分开" do
    FakeHost.ssh("node-1", "docker rm -f kamal-proxy")

    app = build_app

    assert_nothing_raised { Collectors::ProxyCollector.call(app) }

    row = ProxyTarget.where(managed_app: app).sole

    assert row.reachable
    assert_nil row.service_name
    assert_nil row.error
    # 不再把 docker 的报错吞进 /dev/null：这里落的应该是 docker 那句
    # "找不到这个容器"，而不是空字符串——否则这一行会跟"kamal-proxy
    # 正常运行、只是没有任何路由"的那一行（raw 为 nil）长得一模一样
    # （见 final review 分诊 2）。
    assert_predicate row.raw, :present?
  end

  test "只采集本应用的路由，不串到别的 service" do
    FakeHost.proxy_deploy(node: "node-1", service: "blog-web-production",
                          target: "blog-web-production-aaaaaaa:80")
    FakeHost.proxy_deploy(node: "node-1", service: "shop-web-production",
                          target: "shop-web-production-bbbbbbb:80")

    app = build_app
    Collectors::ProxyCollector.call(app)

    rows = ProxyTarget.where(managed_app: app)

    assert_equal [ "blog-web-production" ], rows.pluck(:service_name)
  end

  test "destination 为空时，仍能按 service-role 前缀匹配到路由" do
    FakeHost.proxy_deploy(node: "node-1", service: "blog-web",
                          target: "blog-web-aaaaaaa:80")

    app = build_app(destination: nil)
    Collectors::ProxyCollector.call(app)

    target = ProxyTarget.where(managed_app: app).sole

    assert_equal "blog-web", target.service_name
    assert_match(/blog-web-aaaaaaa/, target.target)
  end

  test "主机不可达时写一条 unreachable 记录，与可达无数据的情况区分开" do
    app = build_app

    fake_session = Object.new
    fake_session.define_singleton_method(:capture_many) do |hosts|
      hosts.index_with do |h|
        Collectors::SshSession::Result.new(host: h, stdout: nil, error: "Net::SSH::Exception: 连接被拒绝")
      end
    end

    original_new = Collectors::SshSession.method(:new)
    Collectors::SshSession.define_singleton_method(:new) { |*_args| fake_session }

    Collectors::ProxyCollector.call(app)

    row = ProxyTarget.where(managed_app: app).sole

    refute row.reachable
    assert_match(/连接被拒绝/, row.error)
    assert_nil row.service_name
  ensure
    Collectors::SshSession.define_singleton_method(:new, original_new)
  end

  test "kamal-proxy 返回无法解析的 JSON 时，原始内容存进 raw 列，而不是当成没有数据" do
    app = build_app

    with_stubbed_stdout(app, "not-json-at-all") do
      Collectors::ProxyCollector.call(app)
    end

    row = ProxyTarget.where(managed_app: app).sole

    assert row.reachable
    assert_nil row.service_name
    assert_equal "not-json-at-all", row.raw
  end

  test "stdout 混入一行非 JSON 的 stderr 噪音时，仍能正常解析出路由载荷" do
    app = build_app

    noisy_stdout = "kamal-proxy: 2026/09/06 warning: something happened\n" \
                   '{"blog-web-production":{"target":"blog-web-production-aaaaaaa:80"}}'

    with_stubbed_stdout(app, noisy_stdout) do
      Collectors::ProxyCollector.call(app)
    end

    target = ProxyTarget.where(managed_app: app).sole

    assert_equal "blog-web-production", target.service_name
    assert_match(/blog-web-production-aaaaaaa/, target.target)
  end

  test "kamal-proxy 返回合法 JSON 但顶层形状认不出来时，同样保留原始 payload" do
    app = build_app

    with_stubbed_stdout(app, '"just-a-string"') do
      Collectors::ProxyCollector.call(app)
    end

    row = ProxyTarget.where(managed_app: app).sole

    assert row.reachable
    assert_nil row.service_name
    assert_equal '"just-a-string"', row.raw
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
