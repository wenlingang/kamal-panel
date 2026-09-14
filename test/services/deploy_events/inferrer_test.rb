require "test_helper"

class DeployEvents::InferrerTest < ActiveSupport::TestCase
  setup do
    @managed_app = ManagedApp.create!(name: "blog",
                                      config_yaml: file_fixture("two_host_deploy.yml").read,
                                      destination: "production")
  end

  # two_host_deploy.yml 的两台机器；一次"全体收敛"必须两台都有可达且 running 的观测
  HOSTS = %w[10.0.0.1 10.0.0.2].freeze

  def observe(host:, version:, status: "running", reachable: true, at: Time.current, role: "web")
    Observation.create!(managed_app: @managed_app, host: host, role: role,
                        container_name: "blog-#{role}-production-#{version}",
                        version: version, docker_status: status,
                        reachable: reachable, observed_at: at)
  end

  def converge(version:, at: Time.current)
    HOSTS.each { |host| observe(host: host, version: version, at: at) }
  end

  test "首次收敛只写基线，不产生事件" do
    converge(version: "aaaaaaa")

    DeployEvents::Inferrer.call(@managed_app)

    assert_equal 0, @managed_app.deploy_events.count,
                 "刚接入的应用早就在跑这一版了，它不是今天部署的"
    assert_equal "aaaaaaa", @managed_app.reload.last_converged_version
    assert_predicate @managed_app.last_converged_at, :present?
  end

  test "收敛版本变化时记一条 inferred" do
    converge(version: "aaaaaaa", at: 10.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)

    converged_at = 1.minute.ago
    converge(version: "bbbbbbb", at: converged_at)
    DeployEvents::Inferrer.call(@managed_app)

    event = @managed_app.deploy_events.sole
    assert_equal "bbbbbbb", event.version
    assert_equal "inferred", event.source
    assert_nil event.started_at
    assert_nil event.performer
    assert_nil event.command
    assert_in_delta converged_at, event.succeeded_at, 1.second
    assert_in_delta converged_at, event.observed_at, 1.second
    assert_equal "bbbbbbb", @managed_app.reload.last_converged_version
  end

  test "混合版本不算收敛：不记事件也不动状态" do
    converge(version: "aaaaaaa", at: 10.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)

    # 滚动部署中途：一台已经是新版，另一台还没换
    observe(host: "10.0.0.1", version: "bbbbbbb")
    observe(host: "10.0.0.2", version: "aaaaaaa")
    DeployEvents::Inferrer.call(@managed_app)

    assert_equal 0, @managed_app.deploy_events.count
    assert_equal "aaaaaaa", @managed_app.reload.last_converged_version
  end

  test "有机器失联不算收敛" do
    converge(version: "aaaaaaa", at: 10.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)

    observe(host: "10.0.0.1", version: "bbbbbbb")
    observe(host: "10.0.0.2", version: nil, status: nil, reachable: false)
    DeployEvents::Inferrer.call(@managed_app)

    assert_equal 0, @managed_app.deploy_events.count,
                 "那台失联的机器可能还跑着旧版，面板并不知道"
    assert_equal "aaaaaaa", @managed_app.reload.last_converged_version
  end

  test "没有任何 running 观测不算收敛" do
    HOSTS.each { |host| observe(host: host, version: "aaaaaaa", status: "exited") }

    DeployEvents::Inferrer.call(@managed_app)

    assert_equal 0, @managed_app.deploy_events.count
    assert_nil @managed_app.reload.last_converged_version
  end

  test "同一版本连续多轮是幂等的" do
    converge(version: "aaaaaaa", at: 10.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)
    converge(version: "bbbbbbb", at: 5.minutes.ago)

    3.times { DeployEvents::Inferrer.call(@managed_app) }

    assert_equal 1, @managed_app.deploy_events.count,
                 "轮询在 burst 期是 2 秒一轮，不幂等的话历史会被同一次部署刷屏"
  end

  test "回滚到很久以前的版本仍然记一条" do
    # 那一版在三个月前部署过，库里躺着一条老的 hook 事件
    old_event = DeployEvent.create!(managed_app: @managed_app, version: "aaaaaaa",
                                    source: "hook", succeeded_at: 3.months.ago,
                                    observed_at: 3.months.ago, created_at: 3.months.ago)
    converge(version: "bbbbbbb", at: 10.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)

    # 现在回滚回 aaaaaaa
    converge(version: "aaaaaaa", at: 1.minute.ago)
    DeployEvents::Inferrer.call(@managed_app)

    inferred = @managed_app.deploy_events.where(source: "inferred", version: "aaaaaaa")
    assert_equal 1, inferred.count,
                 "只按 version 去重会把这次回滚吞掉——它明明是一次真实的部署"
    refute_equal old_event.id, inferred.sole.id
  end

  test "配置外机器留下的旧观测不会永久阻断收敛" do
    converge(version: "aaaaaaa", at: 10.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)

    # 10.0.0.9 早就从 deploy.yml 移除了，但它的观测行被故意保留了下来，
    # 且跑着一个跟当前收敛版本不一致的旧版本。
    observe(host: "10.0.0.9", version: "zzzzzzz", at: 10.minutes.ago)
    converge(version: "bbbbbbb", at: 1.minute.ago)
    DeployEvents::Inferrer.call(@managed_app)

    event = @managed_app.deploy_events.sole
    assert_equal "bbbbbbb", event.version
    assert_equal "inferred", event.source
    assert_equal "bbbbbbb", @managed_app.reload.last_converged_version
  end

  test "同一台机器上不同角色版本不一致不算收敛" do
    converge(version: "aaaaaaa", at: 10.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)

    at = 1.minute.ago
    observe(host: "10.0.0.1", version: "bbbbbbb", at: at, role: "web")
    observe(host: "10.0.0.1", version: "aaaaaaa", at: at, role: "worker")
    observe(host: "10.0.0.2", version: "bbbbbbb", at: at, role: "web")
    DeployEvents::Inferrer.call(@managed_app)

    assert_equal 0, @managed_app.deploy_events.count
    assert_equal "aaaaaaa", @managed_app.reload.last_converged_version
  end

  test "收敛期内已有同版本 hook 事件时让位，但状态照样更新" do
    converge(version: "aaaaaaa", at: 30.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)

    # hook 报了这一版，随后面板才观测到收敛
    DeployEvent.create!(managed_app: @managed_app, version: "bbbbbbb", source: "hook",
                        succeeded_at: 2.minutes.ago)
    converge(version: "bbbbbbb", at: 1.minute.ago)
    DeployEvents::Inferrer.call(@managed_app)

    assert_equal 0, @managed_app.deploy_events.where(source: "inferred").count
    assert_equal "bbbbbbb", @managed_app.reload.last_converged_version,
                 "让位不记事件，但状态必须更新，否则下一次变更会拿错误的时间边界去比"
  end
end
