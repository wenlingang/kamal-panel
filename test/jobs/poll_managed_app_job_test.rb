require "test_helper"

class PollManagedAppJobTest < ExecutionLayerTest
  include ActionCable::TestHelper

  setup do
    FakeHost.start_proxy("node-1")
  end

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
    ManagedApp.create!(
      name: app_name, config_yaml: yaml, destination: "production",
      ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key,
                                      name: "#{app_name} 的 SSH 私钥")
    )
  end

  test "一次轮询同时写入容器观测与路由快照" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")
    FakeHost.proxy_deploy(node: "node-1", service: "blog-web-production",
                          target: "blog-web-production-aaaaaaa:80")

    app = build_app
    PollManagedAppJob.perform_now(app)

    assert_equal "aaaaaaa", Observation.latest_for(app).first.version

    target = ProxyTarget.where(managed_app: app).sole
    assert_equal "blog-web-production", target.service_name
    assert_match(/blog-web-production-aaaaaaa/, target.target)
  end

  test "采集器抛异常时任务不崩溃，并留下 unreachable 痕迹" do
    app = build_app
    app.update_column(:config_yaml, app.config_yaml.sub("127.0.0.1", "192.0.2.1"))
    app.reload

    assert_nothing_raised { PollManagedAppJob.perform_now(app) }
    refute Observation.latest_for(app).first.reachable
  end

  # 广播是这个任务的另一半：总览页能不能不用手动刷新就更新，完全取决于
  # 这里有没有真的往 "overview" 这个 stream 发消息、target 是不是页面
  # 订阅并等着被替换的那个 #overview-grid。只验证"采集写库了"不够——
  # stream 名字或 target id 打错，页面会悄悄停止更新，而所有测试仍然
  # 全绿。这里钉住服务器这一半：广播确实发生、发到了正确的 stream、
  # 替换了正确的 DOM 节点。
  test "deploy.yml 解析不了时，把原因记在 ManagedApp 上，而不只是留一行日志" do
    app = build_app
    # 把 config_yaml 改坏成不再能解析的样子——同时确保 destination 校验
    # 不会先一步拦下来（config_yaml_must_parse 在 destination 已经报错时会跳过）。
    app.update_column(:config_yaml, "not: valid: kamal: yaml: [")
    app.reload

    assert_nil app.last_poll_error

    PollManagedAppJob.perform_now(app)
    app.reload

    assert_predicate app.last_poll_error, :present?,
      "配置解析不了必须留痕在 ManagedApp 上，UI 才能显示出来（见 final review I4）"
    assert_predicate app.last_poll_error_at, :present?
  end

  test "连续失败时 first_poll_error_at 保持首次失败的时间" do
    app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                             destination: "production")
    app.update_column(:config_yaml, "不是配置")
    # update_column 绕过了 config_yaml= 里让 @parsed_config 失效那一步（见
    # ManagedApp#config_yaml=），create! 校验阶段已经把旧的合法配置解析结果
    # 缓存在这个内存对象上了。reload 之后才会跟生产环境一致——生产环境里
    # PollManagedAppJob 走 perform_later，每一轮轮询反序列化出的都是全新
    # 查出来的 ManagedApp，不会带着上一次的缓存。
    app.reload

    travel_to Time.utc(2026, 9, 6, 10, 0, 0) do
      PollManagedAppJob.perform_now(app)
    end
    first = app.reload.first_poll_error_at

    travel_to Time.utc(2026, 9, 6, 12, 0, 0) do
      PollManagedAppJob.perform_now(app)
    end

    assert_equal first, app.reload.first_poll_error_at
    assert_operator app.last_poll_error_at, :>, first
  end

  test "配置恢复可解析后，下一轮轮询会清掉之前记录的解析错误" do
    app = build_app
    app.update_columns(last_poll_error: "之前记录的错误", last_poll_error_at: 1.hour.ago)

    PollManagedAppJob.perform_now(app)
    app.reload

    assert_nil app.last_poll_error, "配置解析恢复正常后，旧的错误痕迹不该继续挂着"
    assert_nil app.last_poll_error_at
  end

  # 广播的是 refresh 而不是渲染好的网格：总览页支持按名称/状态筛选，服务端
  # 不知道哪个浏览器正在筛什么，替它渲染一份全量网格换上去，等于把正在筛选
  # 的人的结果悄悄换回全部。refresh 让每个浏览器带着自己当前的 URL（也就是
  # 各自的筛选条件）回来重新请求，页面用 morph 合并。
  test "轮询完成后向 overview 频道广播一次 refresh，而不是渲染好的网格" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")
    FakeHost.proxy_deploy(node: "node-1", service: "blog-web-production",
                          target: "blog-web-production-aaaaaaa:80")

    app = build_app

    assert_broadcasts("overview", 1) { PollManagedAppJob.perform_now(app) }

    message = ActiveSupport::JSON.decode(broadcasts("overview").last)
    assert_includes message, 'action="refresh"'
    refute_includes message, 'target="overview-grid"',
      "服务端不该再替谁渲染网格——它不知道对方正在筛什么"
  end

  test "采集后也往该应用自己的流广播一次，详情页才会自己活" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")
    app = build_app
    stream = "managed_app_#{app.id}"

    assert_broadcasts(stream, 1) { PollManagedAppJob.perform_now(app) }

    message = ActiveSupport::JSON.decode(broadcasts(stream).last)
    assert_includes message, 'action="replace"'
    assert_includes message, 'target="host-status"',
      "替换目标必须是 #host-status——改了这个 id，详情页会一直停在旧数据上"
    assert_includes message, "aaaaaaa",
      "广播的内容应该是重绘后的机器状态，能看到刚采集到的版本"
  end

  # 广播失败——只限"投递"这一步（Solid Cable 抖动、序列化问题……）——
  # 不该连累已经成功持久化的采集结果。这跟两个采集器各自独立执行是
  # 同一个道理（Task 9）：一次跟"采集是否成功"无关的旁路失败，不该让
  # Solid Queue 把这一轮判定为失败任务去重试一遍其实已经成功的采集。
  #
  # 特意 stub 的是 Turbo::StreamsChannel.broadcast_stream_to——真正
  # 把消息送给 ActionCable 的那一步——而不是更上层的方法，因为下面
  # 那个"渲染阶段异常必须让任务失败"的测试要证明的正是：渲染
  # （ManagedAppStatus、partial）和投递现在是分开的两段，只有投递
  # 这一段被兜底。如果这里 stub 的方法把两段都覆盖了，两个测试就分辨
  # 不出兜底到底护住了哪一半。
  test "广播投递失败不影响采集结果落库，任务本身不因此失败" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")

    app = build_app

    with_stubbed_method(Turbo::StreamsChannel, :broadcast_stream_to, ->(*) { raise "solid cable 抖了一下" }) do
      assert_nothing_raised { PollManagedAppJob.perform_now(app) }
    end

    assert_equal "aaaaaaa", Observation.latest_for(app).first.version
  end

  # 反面：渲染阶段的异常（ManagedAppStatus 算错了、partial 里有
  # bug……）必须照常抛出、让任务失败被重试——不能被"广播失败是自我修复
  # 的退化"这条兜底顺手吞掉，否则一个真正的代码 bug 会退化成"总览页
  # 悄悄不再更新，只有一行日志"，而所有测试仍然全绿，这正是这次
  # review 要堵住的回归。
  test "渲染阶段异常必须让任务失败，不会被广播的兜底吞掉" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")

    app = build_app

    error = with_stubbed_method(ApplicationController, :render, ->(*) { raise "partial 渲染炸了" }) do
      assert_raises(RuntimeError) { PollManagedAppJob.perform_now(app) }
    end

    assert_equal "partial 渲染炸了", error.message
    # 渲染炸了不该拖累采集结果——它们在广播之前已经落库了。
    assert_equal "aaaaaaa", Observation.latest_for(app).first.version
  end

  test "一轮轮询会建立收敛基线，第二轮换版本后推断出一条部署" do
    app = build_app
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")

    PollManagedAppJob.perform_now(app)

    assert_equal "aaaaaaa", app.reload.last_converged_version
    assert_equal 0, app.deploy_events.count, "首次收敛只建基线"

    FakeHost.reset!("node-1")
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "bbbbbbb")

    PollManagedAppJob.perform_now(app)

    event = app.deploy_events.sole
    assert_equal "bbbbbbb", event.version
    assert_equal "inferred", event.source
    assert_empty DeployAlerts.new(app).list, "推断行本身已被观测背书，不该触发告警"
  end

  test "一轮轮询会回填 observed_at" do
    app = build_app
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")
    event = DeployEvent.create!(managed_app: app, version: "aaaaaaa", source: "hook",
                                succeeded_at: 1.minute.ago)

    PollManagedAppJob.perform_now(app)

    assert_predicate event.reload.observed_at, :present?
  end

  private
    def with_stubbed_method(receiver, method_name, replacement)
      original = receiver.method(method_name)
      receiver.define_singleton_method(method_name, &replacement)
      yield
    ensure
      receiver.define_singleton_method(method_name, original)
    end

  # 停用时可能已经有一轮采集在队列里。它不该把应用复活着采一遍——那会在
  # 停用之后再攒一条失败观测（凭据已经被释放了）。
  test "已经入队的采集遇到已停用的应用时直接放弃" do
    app = build_app
    app.deactivate!

    assert_no_difference -> { Observation.where(managed_app: app).count } do
      PollManagedAppJob.perform_now(app)
    end
  end
end
