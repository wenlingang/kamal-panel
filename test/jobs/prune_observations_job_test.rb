require "test_helper"

class PruneObservationsJobTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(
      name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )
  end

  test "删除超过保留期的观测" do
    Observation.create!(managed_app: @app, host: "10.0.0.1",
                        docker_status: "running", observed_at: 20.days.ago)
    Observation.create!(managed_app: @app, host: "10.0.0.1",
                        docker_status: "running", observed_at: 1.day.ago)

    PruneObservationsJob.perform_now

    assert_equal 1, Observation.where(managed_app: @app).count
  end

  test "即使全部超期，也保留每台主机最近一条——否则界面会变空白" do
    Observation.create!(managed_app: @app, host: "10.0.0.1",
                        docker_status: "running", observed_at: 100.days.ago)
    Observation.create!(managed_app: @app, host: "10.0.0.1",
                        docker_status: "running", observed_at: 90.days.ago)

    PruneObservationsJob.perform_now

    remaining = Observation.where(managed_app: @app)

    assert_equal 1, remaining.count
    assert_in_delta 90.days.ago.to_i, remaining.first.observed_at.to_i, 60
  end

  # 注意：这里不能只造一条过期的 ProxyTarget 就断言清空为 0——那条记录
  # 同时也是它所在 (app, host) 分组里"最近的一条"，跟 Observation 的
  # "即使全部超期，也保留每台主机最近一条"是同一条规则，对 ProxyTarget
  # 同样成立（否则会自相矛盾）。这里造两条，验证真正超期且已被更新
  # 记录取代的那条会被删掉，同时最近一条被保留。
  test "同样清理 ProxyTarget" do
    ProxyTarget.create!(managed_app: @app, host: "10.0.0.1",
                        service_name: "blog-web-production", observed_at: 20.days.ago)
    ProxyTarget.create!(managed_app: @app, host: "10.0.0.1",
                        service_name: "blog-web-production", observed_at: 1.day.ago)

    PruneObservationsJob.perform_now

    remaining = ProxyTarget.where(managed_app: @app)
    assert_equal 1, remaining.count
    assert_in_delta 1.day.ago.to_i, remaining.first.observed_at.to_i, 60
  end

  # Task 11 花了两轮 review 才立住的承诺：一台失联的机器，界面回落到它
  # 「最近一次可达」的观测,并标注这条数据有多旧——绝不清空整行(spec 6.4)。
  #
  # 如果 prune 只按 (app, host) 保留 observed_at 最大的一条,对一台已经
  # 失联超过保留期的机器来说,"最大"的那条恰好是不可达的记录,而
  # last_known_rows 唯一能回落到的、真正有用的"上次已知状态"——最近一次
  # 可达的观测——比它更旧,会被当成过期数据删掉。于是这台失联时间最长、
  # 操作者最需要历史的机器,反而最先失去历史,面板退化成
  # "无可用的历史状态",这个回归会随时间悄悄发生,且没有任何测试会因为
  # "刚失联"的场景发现它。
  #
  # 这里刻意让可达的那条观测比保留期还旧得多(100 天前),不可达的观测
  # 也在保留期之外(50 天前)——两条都够格被当成"过期"删掉,但可达的那条
  # 必须活下来,因为它是唯一的回退依据。
  # prune 是按 (managed_app_id, host) 分组的，不是按 managed_app_id 单独
  # 分组——如果分组打错了范围（比如漏掉 host，或者反过来漏掉
  # managed_app_id 导致跨应用互相踩），一个多主机应用里"只有部分主机
  # 过期"的场景最容易把这种错误暴露出来：错误分组要么会把还没过期的
  # 主机也删掉,要么会把该删的主机保留下来。
  test "一个应用多台主机，只清理其中过期的那些，各自独立判断" do
    Observation.create!(managed_app: @app, host: "10.0.0.1",
                        docker_status: "running", observed_at: 20.days.ago)
    Observation.create!(managed_app: @app, host: "10.0.0.1",
                        docker_status: "running", observed_at: 1.day.ago)

    Observation.create!(managed_app: @app, host: "10.0.0.2",
                        docker_status: "running", observed_at: 2.days.ago)

    Observation.create!(managed_app: @app, host: "10.0.0.3",
                        docker_status: "running", observed_at: 30.days.ago)

    PruneObservationsJob.perform_now

    remaining = Observation.where(managed_app: @app).order(:host)

    assert_equal %w[10.0.0.1 10.0.0.2 10.0.0.3], remaining.map(&:host).sort
    assert_equal 3, remaining.count

    host_1 = remaining.find { |o| o.host == "10.0.0.1" }
    assert_in_delta 1.day.ago.to_i, host_1.observed_at.to_i, 60,
      "过期的那条应该被删掉，只留最近一条"

    host_3 = remaining.find { |o| o.host == "10.0.0.3" }
    assert_in_delta 30.days.ago.to_i, host_3.observed_at.to_i, 60,
      "唯一一条即使超期也要保留，不能因为分组混进了别的主机而被误删"
  end

  test "prune 的保留条件必须对齐回退真正读取的条件——可达但没有容器的行不能顶替带容器的那一行" do
    # D0：机器正常跑着容器（最旧）
    # D1：容器被移除，机器仍可达（比 D0 新）
    # D2：机器彻底下线（最新）
    # 三条全部超过保留期。旧的保留条件是"最新一条 + 最新一条 reachable"，
    # 会保留 D2（最新）与 D1（最新 reachable），删掉 D0——但回退
    # （ManagedAppStatus#last_reachable_observation）要的是"最新一条 reachable
    # 且带容器"的行，也就是 D0。删掉它会让回退无落点可用（见 final review I6）。
    d0 = Observation.create!(managed_app: @app, host: "127.0.0.1", role: "web",
      container_name: "blog-web-production-aaaaaaa", version: "aaaaaaa",
      docker_status: "running", reachable: true, observed_at: 100.days.ago)
    Observation.create!(managed_app: @app, host: "127.0.0.1", role: "web",
      container_name: nil, version: nil, docker_status: nil,
      reachable: true, observed_at: 90.days.ago)
    Observation.create!(managed_app: @app, host: "127.0.0.1", role: "web",
      reachable: false, observed_at: 80.days.ago)

    PruneObservationsJob.perform_now

    assert Observation.exists?(d0.id),
      "回退真正会用到的那一条（最新一条可达且带容器）不能被 prune 删掉"

    status = ManagedAppStatus.new(@app)
    row = status.last_known_rows.find { |r| r[:host] == "127.0.0.1" }

    assert_equal "aaaaaaa", row[:version],
      "prune 之后回退仍然必须能找到落点，而不是\"无可用的历史状态\""
    assert_not_nil row[:stale_since]
  end

  test "主机失联超过保留期后，prune 仍保留其最近一次可达观测，故障回退不失效" do
    Observation.create!(managed_app: @app, host: "127.0.0.1", role: "web",
                        container_name: "blog-web-production-aaaaaaa", version: "aaaaaaa",
                        docker_status: "running", reachable: true, observed_at: 100.days.ago)
    Observation.create!(managed_app: @app, host: "127.0.0.1", role: "web",
                        reachable: false, observed_at: 50.days.ago)

    PruneObservationsJob.perform_now

    status = ManagedAppStatus.new(@app)
    row = status.last_known_rows.find { |r| r[:host] == "127.0.0.1" }

    assert_equal "aaaaaaa", row[:version],
      "prune 不能把唯一能回退到的可达历史观测删掉，否则失联最久的机器最先失去历史"
    assert_not_nil row[:stale_since], "回退状态必须带上它有多旧，不能悄悄变回一个没有时间戳的行"
  end
end
