require "test_helper"

class ManagedAppStatusTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear # cached_app_hosts 缓存键含 id，SQLite 回滚后可能复用 id

    # 两台机器（10.0.0.1、10.0.0.2）都配置在 deploy.yml 里——这样
    # observe() 用到的主机才会跟"配置里到底有哪些机器"对得上，才能
    # 测出"配置里有、但从没采集过"的那台机器。
    @app = ManagedApp.create!(
      name: "blog", config_yaml: file_fixture("two_host_deploy.yml").read,
      destination: "production"
    )
    @now = Time.current
  end

  def observe(host:, version: nil, docker_status: "running", health: nil, reachable: true,
              role: "web", observed_at: @now)
    Observation.create!(
      managed_app: @app, host: host, role: role,
      container_name: version && "blog-#{role}-production-#{version}",
      version: version, docker_status: docker_status, health: health,
      reachable: reachable, observed_at: observed_at
    )
  end

  # 一台可达、但没有匹配到任何容器的机器——docker_status/version/
  # container_name 全部是 nil，这正是 Collectors::ContainerCollector 在
  # "docker ps 没找到匹配的容器"时落库的形状（它的 empty_row 只有
  # base_row：host/reachable/observed_at，没有别的字段）。用一个专门
  # 命名的帮助方法而不是让调用方自己拼 `version: nil, docker_status: nil`，
  # 是因为原来的测试套件从没写出过这个形状——helper 的默认值悄悄把它
  # 变成了不可表达的状态，这正是这次漏判 bug 能一直藏到评审才被发现的
  # 原因之一。
  def observe_no_containers(host:, reachable: true)
    observe(host: host, version: nil, docker_status: nil, reachable: reachable)
  end

  test "所有机器版本一致且运行中 → ok" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", version: "aaaaaaa")

    status = ManagedAppStatus.new(@app)

    assert_equal :ok, status.level
    refute status.drift?
  end

  test "不同机器版本不一致 → drift，且优先级最高" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", version: "bbbbbbb")

    status = ManagedAppStatus.new(@app)

    assert_equal :drift, status.level
    assert status.drift?
    assert_equal %w[aaaaaaa bbbbbbb], status.versions.sort
  end

  test "版本漂移优先于容器异常" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", version: "bbbbbbb", docker_status: "exited")

    assert_equal :drift, ManagedAppStatus.new(@app).level
  end

  test "已停止的旧版本不算进漂移判断" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.1", version: "0000000", docker_status: "exited")
    observe(host: "10.0.0.2", version: "aaaaaaa")

    assert_equal :ok, ManagedAppStatus.new(@app).level
  end

  test "同一台机器上的多个角色版本一致时不算漂移" do
    observe(host: "10.0.0.1", role: "web", version: "aaaaaaa")
    observe(host: "10.0.0.1", role: "worker", version: "aaaaaaa")
    observe(host: "10.0.0.2", role: "web", version: "aaaaaaa")
    observe(host: "10.0.0.2", role: "worker", version: "aaaaaaa")

    assert_equal :ok, ManagedAppStatus.new(@app).level
  end

  test "容器 unhealthy → unhealthy" do
    observe(host: "10.0.0.1", version: "aaaaaaa", health: "unhealthy")
    observe(host: "10.0.0.2", version: "aaaaaaa")

    assert_equal :unhealthy, ManagedAppStatus.new(@app).level
  end

  test "有机器失联 → unreachable" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", reachable: false)

    assert_equal :unreachable, ManagedAppStatus.new(@app).level
  end

  # Critical：可达的机器如果一个容器都没匹配到（从没部署过，或者容器被
  # 整个删掉了），不能落到 :ok——那看起来和"一切正常"一模一样，而实际上
  # 是"这台机器完全没有在服务"。
  test "可达但没有匹配到任何容器的机器 → unhealthy，而不是正常" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe_no_containers(host: "10.0.0.2")

    assert_equal :unhealthy, ManagedAppStatus.new(@app).level
  end

  test "所有机器都可达但都没有匹配到容器时，同样是 unhealthy" do
    observe_no_containers(host: "10.0.0.1")
    observe_no_containers(host: "10.0.0.2")

    assert_equal :unhealthy, ManagedAppStatus.new(@app).level
  end

  # Important：deploy.yml 里配置了但从来没有一条 Observation 的机器，
  # 不能被状态计算悄悄忽略——那等于"没看过"被当成了"看过、没问题"。
  test "配置里存在但从未采集过的机器 → 不算正常，视为机器失联" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    # 10.0.0.2 在 two_host_deploy.yml 里配置了，但这里故意不为它写任何
    # Observation——模拟"新加的机器还没轮到采集"或"数据被清理过"。

    assert_equal :unreachable, ManagedAppStatus.new(@app).level
  end

  test "数据过期时不能显示正常——3 秒扫视的那个徽章不能把「我没能看」渲染成「一切正常」" do
    observe(host: "10.0.0.1", version: "aaaaaaa", observed_at: @now - 1.hour)
    observe(host: "10.0.0.2", version: "aaaaaaa", observed_at: @now - 1.hour)

    status = ManagedAppStatus.new(@app)

    assert status.stale?
    refute_equal :ok, status.level,
      "所有观测都是 1 小时前时，level 不能是 :ok——采集停摆必须能在总览页的徽章上看出来（见 final review C1）"
    assert_equal :unreachable, status.level,
      "过期与失联共享同一个黄色档位，不新增第六态（见 ManagedAppStatus#level 注释）"
  end

  test "从未采集过 → unknown" do
    assert_equal :unknown, ManagedAppStatus.new(@app).level
  end

  test "每个状态都有文字标识，不只靠颜色" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", version: "aaaaaaa")

    assert_predicate ManagedAppStatus.new(@app).label, :present?
  end

  # Important：数据年龄必须来自正在展示的这批观测，而不是"此刻数据库里
  # 最新一次采集是什么时候"——否则轮询中会出现"页面显示的数据年龄，比
  # 页面上其它数据实际的时间还新"这种自相矛盾的情况。
  test "数据年龄来自已经加载的这批观测，而不是重新查询出的更新时间" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", version: "aaaaaaa")
    status = ManagedAppStatus.new(@app)

    assert_equal :ok, status.level # 触发并缓存这一批 observations

    # 模拟"页面渲染之后，又来了一轮更新的采集"——如果 #observed_at 重新
    # 查库，会返回这个更新的时间，而不是页面上实际展示的那批数据的时间。
    observe(host: "10.0.0.1", version: "aaaaaaa", observed_at: @now + 1.hour)

    assert_equal @now.to_i, status.observed_at.to_i
  end

  # Important（review 回合二）：数据年龄这行字唯一诚实的说法是"这里没有
  # 一条数据比 N 更旧"。如果取最新一台的时间，一台 3 小时没采到的机器
  # 会被一台 12 秒前刚采到的机器的时间戳掩盖——这正是数据年龄指示器
  # 唯一不能犯的方向的谎：让人以为整页数据都是新的。
  test "数据年龄取最旧的一台机器，而不是最新的一台" do
    observe(host: "10.0.0.1", version: "aaaaaaa", observed_at: @now - 3.hours)
    observe(host: "10.0.0.2", version: "aaaaaaa", observed_at: @now)

    status = ManagedAppStatus.new(@app)

    assert_equal (@now - 3.hours).to_i, status.observed_at.to_i,
      "必须报告最旧一台的年龄，取最新的会把"\
      "「3 小时没采到」藏在「12 秒前」背后"
  end

  # Important（review 回合二）：失联的机器如果压根没有任何一条「可达」的
  # 历史观测，last_known_rows 没有"上次"可回落——这是最容易让空白行
  # 溜到界面上的分支，必须验证它诚实地保持"失联、没有历史"，而不是
  # 悄悄编出一个版本号，也不是把整行清空。
  test "失联但从来没有过可达的观测 → 保留失联状态，不编造历史版本" do
    observe(host: "10.0.0.1", reachable: false, version: nil, docker_status: nil)
    observe(host: "10.0.0.2", version: "aaaaaaa")

    status = ManagedAppStatus.new(@app)
    row = status.last_known_rows.find { |r| r[:host] == "10.0.0.1" }

    assert_equal false, row[:reachable]
    assert_nil row[:version], "没有可回落的历史状态时不能编造版本号"
    assert_nil row[:stale_since], "没有历史状态就不该出现一个假的\"上次\"时间戳"
  end

  # Important（review 回合二）：两台机器都出现过、其中一台失联时，回落
  # 必须只用它自己的历史记录。如果回退逻辑漏了 host 过滤，会读到"最近
  # 一次全局可达的观测"——那可能是另一台机器的版本，面板会在 A 的名字
  # 底下显示 B 的版本，这比空白更危险。
  test "失联主机的回退状态只用它自己的历史记录，不会串到另一台机器" do
    observe(host: "10.0.0.1", version: "aaaaaaa", observed_at: @now)
    observe(host: "10.0.0.2", version: "bbbbbbb", observed_at: @now)

    # 10.0.0.1 之后失联
    observe(host: "10.0.0.1", version: nil, docker_status: nil, reachable: false,
            observed_at: @now + 1.minute)

    status = ManagedAppStatus.new(@app)
    row = status.last_known_rows.find { |r| r[:host] == "10.0.0.1" }

    assert_equal "aaaaaaa", row[:version],
      "失联主机的回退必须用它自己上一次可达的记录，不能读到另一台机器的版本"
    refute_equal "bbbbbbb", row[:version]
  end

  # Minor（review 回合二，判断题）：一台曾经采集过、但已经不在当前
  # deploy.yml 里的机器——不删掉这一行（删掉等于悄悄丢弃"它曾经存在过"
  # 这条信息），但绝不能让它继续无条件地显示"正常"，那等于面板替一台
  # 已经不属于这个应用的机器背书。这里验证 host_rows 能区分"仍在配置中"
  # 与"已被移出配置"。
  test "曾经采集过、但已从当前配置移除的机器：仍出现在 host_rows 里，但标记为不在配置中" do
    app = ManagedApp.create!(
      name: "blog-#{SecureRandom.hex(4)}", config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )

    Observation.create!(managed_app: app, host: "127.0.0.1", role: "web",
      container_name: "blog-web-production-aaaaaaa", version: "aaaaaaa",
      docker_status: "running", reachable: true, observed_at: @now)
    # "10.9.9.9" 曾经被采集过，但 simple_deploy.yml 里从未配置过它——
    # 模拟"这台机器后来从 deploy.yml 里被删掉了"。
    Observation.create!(managed_app: app, host: "10.9.9.9", role: "web",
      container_name: "blog-web-production-zzzzzzz", version: "zzzzzzz",
      docker_status: "running", reachable: true, observed_at: @now)

    status = ManagedAppStatus.new(app)
    rows = status.host_rows.index_by { |r| r[:host] }

    assert rows["127.0.0.1"][:configured]
    refute rows["10.9.9.9"][:configured],
      "已经不在 deploy.yml 里的机器不能被当成\"仍属于这个应用\"的普通一行"
  end

  # Important（review 回合三，低估）：数据年龄如果只看 #observations 这批
  # 记录本身的最旧值，一台配置了但从没被采集过的机器会完全隐形——它对
  # "数据年龄"这个计算不贡献任何时间戳，于是指示器可能显示"刚采集过"，
  # 而实际上有一台机器面板压根没看过它。一台从没被看过的机器，是"最旧"，
  # 不是"不存在"。
  test "配置里有一台从未采集过的机器时，数据年龄指示器不能显示新鲜" do
    observe(host: "10.0.0.1", version: "aaaaaaa", observed_at: @now)
    # 10.0.0.2 在 two_host_deploy.yml 里配置了，但故意不写任何 Observation。

    status = ManagedAppStatus.new(@app)

    assert status.stale?,
      "有配置的机器一条观测都没有时，指示器不能显示「新鲜」——它对这台机器一无所知，" \
      "这跟「所有机器都很新」是完全不同的两件事"
  end

  # Important（review 回合三，高估）：数据年龄如果不按"当下配置里有哪些
  # 机器"过滤，一台已经从 deploy.yml 移除、但历史上被采集过的机器会永远
  # 拖着它的旧时间戳（Observation 只追加、不会因为配置改了就消失），把
  # 整个应用钉死在"已过期"——这是"狼来了"式的回归：指示器永远红，操作者
  # 会学会不再看它。
  test "唯一拖累新鲜度的是已经不在配置里的机器时，数据年龄指示器不能显示过期" do
    app = ManagedApp.create!(
      name: "blog-#{SecureRandom.hex(4)}", config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )

    Observation.create!(managed_app: app, host: "127.0.0.1", role: "web",
      container_name: "blog-web-production-aaaaaaa", version: "aaaaaaa",
      docker_status: "running", reachable: true, observed_at: @now)
    # "10.9.9.9" 不在 simple_deploy.yml 里，但留着一条很旧的历史观测——
    # 模拟"这台机器很久以前被下线、从配置里删掉了"。
    Observation.create!(managed_app: app, host: "10.9.9.9", role: "web",
      container_name: "blog-web-production-zzzzzzz", version: "zzzzzzz",
      docker_status: "running", reachable: true, observed_at: @now - 3.hours)

    status = ManagedAppStatus.new(app)

    refute status.stale?,
      "唯一超龄的贡献者是一台已经不在配置里的机器时，指示器不该显示「已过期」——" \
      "它已经被下线横幅单独标注了，不该再拖累这个全局数字"
  end

  # 回归护栏：所有配置的机器数据都新鲜时，必须仍然显示新鲜——防止上面
  # 两个修复本身矫枉过正，把"新鲜"这条路也堵死了。
  test "读不到 proxy 状态时，接流量必须是未知（nil），不能编造成「否」" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    # 没有为这台机器创建任何 ProxyTarget——面板压根没问到 proxy 状态。

    status = ManagedAppStatus.new(@app)
    row = status.host_rows.find { |r| r[:host] == "10.0.0.1" }

    assert_nil row[:routed],
      "面板没问到 kamal-proxy 时，「接流量」必须是未知，不能渲染成确定的「否」（见 final review I2）"
  end

  test "该机器最新一条 ProxyTarget 是 unreachable 时，接流量同样是未知" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    ProxyTarget.create!(managed_app: @app, host: "10.0.0.1", reachable: false,
      error: "连接被拒绝", observed_at: @now)

    status = ManagedAppStatus.new(@app)
    row = status.host_rows.find { |r| r[:host] == "10.0.0.1" }

    assert_nil row[:routed]
  end

  test "确实拿到路由表时，接流量给出确定的 true/false" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    ProxyTarget.create!(managed_app: @app, host: "10.0.0.1", service_name: "blog-web-production",
      target: "blog-web-production-aaaaaaa:80", observed_at: @now)

    status = ManagedAppStatus.new(@app)
    row = status.host_rows.find { |r| r[:host] == "10.0.0.1" }

    assert_equal true, row[:routed]
  end

  test "陈旧阈值等于空闲轮询间隔的三倍，而不是硬编码的常量" do
    assert_equal PollCadence::IDLE * 3, ManagedAppStatus.stale_threshold
  end

  test "陈旧阈值随 PollCadence::IDLE 变化，证明它是推导出来的而不是写死的" do
    original = PollCadence::IDLE
    silence_warnings { PollCadence.const_set(:IDLE, 10.minutes) }

    assert_equal 30.minutes, ManagedAppStatus.stale_threshold
  ensure
    silence_warnings { PollCadence.const_set(:IDLE, original) }
  end

  test "所有配置的机器数据都新鲜时，数据年龄指示器应显示新鲜" do
    observe(host: "10.0.0.1", version: "aaaaaaa", observed_at: @now)
    observe(host: "10.0.0.2", version: "aaaaaaa", observed_at: @now)

    status = ManagedAppStatus.new(@app)

    refute status.stale?
  end
end
