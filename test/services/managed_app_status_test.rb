require "test_helper"

class ManagedAppStatusTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear # cached_app_hosts cache key contains the id, and SQLite may reuse ids after rollback

    # Both machines (10.0.0.1, 10.0.0.2) are configured in deploy.yml -- so that the hosts observe()
    # uses line up with "which machines are actually in the config", making it possible to test the
    # machine that is "in the config but never collected".
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

  # A machine that is reachable but matched no container -- docker_status/version/ container_name
  # are all nil, which is exactly the shape Collectors::ContainerCollector writes when "docker ps
  # found no matching container" (its empty_row has only base_row: host/reachable/observed_at, no
  # other fields). A specially named helper rather than having callers assemble `version: nil,
  # docker_status: nil` themselves, because the original test suite never wrote out this shape --
  # the helper's defaults quietly made it an inexpressible state, which is one of the reasons this
  # missed-detection bug stayed hidden until review.
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

  # Critical: if a reachable machine matched no container at all (never deployed, or the container
  # was deleted entirely), it must not fall to :ok -- that looks exactly like "everything is fine",
  # while in reality it is "this machine isn't serving at all".
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

  # Important: a machine configured in deploy.yml but with no Observation ever must not be quietly
  # ignored by the status computation -- that is "never looked at" being treated as "looked at, no
  # problem".
  test "配置里存在但从未采集过的机器 → 不算正常，视为机器失联" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    # 10.0.0.2 is configured in two_host_deploy.yml, but here we deliberately write no
    # Observation for it -- simulating "a newly added machine whose turn to be collected hasn't
    # come" or "the data was cleaned up".

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

  # Important: data age must come from the batch of observations being displayed, not from "when the
  # latest collection in the database is right now" -- otherwise polling would produce the
  # self-contradiction of "the data age shown on the page is newer than the actual time of the other
  # data on the page".
  test "数据年龄来自已经加载的这批观测，而不是重新查询出的更新时间" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", version: "aaaaaaa")
    status = ManagedAppStatus.new(@app)

    assert_equal :ok, status.level # triggers and caches this batch of observations

    # Simulate "a newer collection round arrived after the page was rendered" -- if #observed_at
    # re-queried the DB, it would return this newer time rather than the time of the batch of data
    # actually displayed on the page.
    observe(host: "10.0.0.1", version: "aaaaaaa", observed_at: @now + 1.hour)

    assert_equal @now.to_i, status.observed_at.to_i
  end

  # Important (review round 2): the only honest wording for the data-age line is "no data here is
  # older than N". If we took the latest machine's time, a machine not collected for 3 hours would
  # be masked by the timestamp of a machine collected 12 seconds ago -- exactly the one direction in
  # which the data-age indicator must never lie: making people think the whole page's data is fresh.
  test "数据年龄取最旧的一台机器，而不是最新的一台" do
    observe(host: "10.0.0.1", version: "aaaaaaa", observed_at: @now - 3.hours)
    observe(host: "10.0.0.2", version: "aaaaaaa", observed_at: @now)

    status = ManagedAppStatus.new(@app)

    assert_equal (@now - 3.hours).to_i, status.observed_at.to_i,
      "必须报告最旧一台的年龄，取最新的会把"\
      "「3 小时没采到」藏在「12 秒前」背后"
  end

  # Important (review round 2): if an unreachable machine has no "reachable" historical observation
  # at all, last_known_rows has no "last time" to fall back to -- this is the branch most likely to
  # let a blank row slip onto the UI, and it must be verified to honestly stay "unreachable, no
  # history", rather than quietly inventing a version, or clearing the whole row.
  test "失联但从来没有过可达的观测 → 保留失联状态，不编造历史版本" do
    observe(host: "10.0.0.1", reachable: false, version: nil, docker_status: nil)
    observe(host: "10.0.0.2", version: "aaaaaaa")

    status = ManagedAppStatus.new(@app)
    row = status.last_known_rows.find { |r| r[:host] == "10.0.0.1" }

    assert_equal false, row[:reachable]
    assert_nil row[:version], "没有可回落的历史状态时不能编造版本号"
    assert_nil row[:stale_since], "没有历史状态就不该出现一个假的\"上次\"时间戳"
  end

  # Important (review round 2): when both machines have appeared and one is unreachable, the
  # fallback must use only its own history. If the fallback logic missed the host filter, it would
  # read "the most recent globally reachable observation" -- possibly another machine's version, and
  # the panel would show B's version under A's name, which is more dangerous than blank.
  test "失联主机的回退状态只用它自己的历史记录，不会串到另一台机器" do
    observe(host: "10.0.0.1", version: "aaaaaaa", observed_at: @now)
    observe(host: "10.0.0.2", version: "bbbbbbb", observed_at: @now)

    # 10.0.0.1 goes unreachable afterwards
    observe(host: "10.0.0.1", version: nil, docker_status: nil, reachable: false,
            observed_at: @now + 1.minute)

    status = ManagedAppStatus.new(@app)
    row = status.last_known_rows.find { |r| r[:host] == "10.0.0.1" }

    assert_equal "aaaaaaa", row[:version],
      "失联主机的回退必须用它自己上一次可达的记录，不能读到另一台机器的版本"
    refute_equal "bbbbbbb", row[:version]
  end

  # Minor (review round 2, a judgment call): a machine that was collected once but is no longer in
  # the current deploy.yml -- don't delete the row (deleting would quietly discard the information
  # "it once existed"), but it must never keep showing "ok" unconditionally, which would be the
  # panel vouching for a machine that no longer belongs to this app. This verifies host_rows can
  # distinguish "still in the config" from "removed from the config".
  test "曾经采集过、但已从当前配置移除的机器：仍出现在 host_rows 里，但标记为不在配置中" do
    app = ManagedApp.create!(
      name: "blog-#{SecureRandom.hex(4)}", config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )

    Observation.create!(managed_app: app, host: "127.0.0.1", role: "web",
      container_name: "blog-web-production-aaaaaaa", version: "aaaaaaa",
      docker_status: "running", reachable: true, observed_at: @now)
    # "10.9.9.9" was collected once, but simple_deploy.yml never configured it --
    # simulating "this machine was later deleted from deploy.yml".
    Observation.create!(managed_app: app, host: "10.9.9.9", role: "web",
      container_name: "blog-web-production-zzzzzzz", version: "zzzzzzz",
      docker_status: "running", reachable: true, observed_at: @now)

    status = ManagedAppStatus.new(app)
    rows = status.host_rows.index_by { |r| r[:host] }

    assert rows["127.0.0.1"][:configured]
    refute rows["10.9.9.9"][:configured],
      "已经不在 deploy.yml 里的机器不能被当成\"仍属于这个应用\"的普通一行"
  end

  # Important (review round 3, underestimate): if data age looks only at the oldest value among the
  # records of #observations, a machine that is configured but never collected becomes completely
  # invisible -- it contributes no timestamp to the "data age" computation, so the indicator may say
  # "just collected", while actually there is a machine the panel never looked at at all. A machine
  # never looked at is "oldest", not "nonexistent".
  test "配置里有一台从未采集过的机器时，数据年龄指示器不能显示新鲜" do
    observe(host: "10.0.0.1", version: "aaaaaaa", observed_at: @now)
    # 10.0.0.2 is configured in two_host_deploy.yml, but we deliberately write no Observation.

    status = ManagedAppStatus.new(@app)

    assert status.stale?,
      "有配置的机器一条观测都没有时，指示器不能显示「新鲜」——它对这台机器一无所知，" \
      "这跟「所有机器都很新」是完全不同的两件事"
  end

  # Important (review round 3, overestimate): if data age isn't filtered by "which machines are in
  # the current config", a machine removed from deploy.yml but collected historically would forever
  # drag its old timestamp along (Observations are append-only and don't vanish when config
  # changes), pinning the whole app at "stale" -- a "cry wolf" regression: the indicator is always
  # red, and operators learn to stop looking at it.
  test "唯一拖累新鲜度的是已经不在配置里的机器时，数据年龄指示器不能显示过期" do
    app = ManagedApp.create!(
      name: "blog-#{SecureRandom.hex(4)}", config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )

    Observation.create!(managed_app: app, host: "127.0.0.1", role: "web",
      container_name: "blog-web-production-aaaaaaa", version: "aaaaaaa",
      docker_status: "running", reachable: true, observed_at: @now)
    # "10.9.9.9" isn't in simple_deploy.yml, but a very old historical observation is kept --
    # simulating "this machine was decommissioned long ago and removed from the config".
    Observation.create!(managed_app: app, host: "10.9.9.9", role: "web",
      container_name: "blog-web-production-zzzzzzz", version: "zzzzzzz",
      docker_status: "running", reachable: true, observed_at: @now - 3.hours)

    status = ManagedAppStatus.new(app)

    refute status.stale?,
      "唯一超龄的贡献者是一台已经不在配置里的机器时，指示器不该显示「已过期」——" \
      "它已经被下线横幅单独标注了，不该再拖累这个全局数字"
  end

  # Regression guard: when all configured machines' data is fresh, it must still show fresh -- to
  # prevent the two fixes above from overcorrecting and blocking the "fresh" path too.
  test "读不到 proxy 状态时，接流量必须是未知（nil），不能编造成「否」" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    # No ProxyTarget was created for this machine -- the panel never asked about proxy status at
    # all.

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
