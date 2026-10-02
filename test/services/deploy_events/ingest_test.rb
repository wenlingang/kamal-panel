require "test_helper"

class DeployEvents::IngestTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  def ingest(phase, version: "aaaaaaa", performer: "ci", command: "deploy",
             recorded_at: Time.current)
    DeployEvents::Ingest.call(
      managed_app: @app, phase: phase,
      attributes: { version: version, performer: performer, command: command,
                    recorded_at: recorded_at }
    )
  end

  test "pre-deploy 建行，只填 started_at" do
    result = ingest("started")

    assert result[:changed]
    assert_predicate result[:event].started_at, :present?
    assert_nil result[:event].succeeded_at
    assert_equal "hook", result[:event].source
  end

  test "post-deploy 补上同一次尝试，而不是另建一行" do
    started = ingest("started")[:event]
    result = ingest("succeeded")

    assert_equal started.id, result[:event].id
    assert result[:changed]
    assert_predicate result[:event].succeeded_at, :present?
    assert_equal 1, DeployEvent.count
  end

  test "pre 丢包、post 先到时建出只有 succeeded_at 的行" do
    result = ingest("succeeded")

    assert_nil result[:event].started_at
    assert_predicate result[:event].succeeded_at, :present?
  end

  test "重复的 pre-deploy 不建新行，也不算状态变化" do
    ingest("started")
    result = ingest("started")

    assert_equal 1, DeployEvent.count
    refute result[:changed], "重复上报不应再撬动一次 burst 轮询"
  end

  test "同一版本被重复部署是两行" do
    ingest("started")
    ingest("succeeded")
    ingest("started")

    assert_equal 2, DeployEvent.count
  end

  test "配对不跨应用" do
    other = ManagedApp.create!(name: "other", config_yaml: file_fixture("simple_deploy.yml").read,
                               destination: "production")
    DeployEvents::Ingest.call(managed_app: other, phase: "started",
                              attributes: { version: "aaaaaaa", performer: "ci",
                                            command: "deploy", recorded_at: Time.current })

    ingest("succeeded")

    assert_equal 2, DeployEvent.count
    assert_nil other.deploy_events.sole.succeeded_at
  end

  test "重复的 post-deploy 不建新行，也不算状态变化" do
    ingest("started")
    ingest("succeeded")
    result = ingest("succeeded")

    assert_equal 1, DeployEvent.count
    refute result[:changed], "重复的 succeeded 上报不应再撬动一次 burst 轮询"
  end

  test "超出去重窗口的同版本 post 仍然建新行" do
    ingest("started")
    first = ingest("succeeded")[:event]
    # 把上一行的 succeeded_at 拨到窗口之外，模拟"很久以后才到的重试"，
    # 而不是真的等 1 分钟——这样测试不用 sleep 也不用依赖 travel 的当前时刻假设。
    first.update!(succeeded_at: (DeployEvents::Ingest::DUPLICATE_WINDOW + 1.second).ago)

    result = ingest("succeeded")

    assert_equal 2, DeployEvent.count
    assert result[:changed]
    refute_equal first.id, result[:event].id
  end

  test "3 小时前的未收尾同版本行早已不像同一次部署，新的 pre 不会认领它" do
    stale = ingest("started")[:event]
    stale.update!(started_at: 3.hours.ago)

    result = ingest("started")

    assert result[:changed]
    refute_equal stale.id, result[:event].id
    assert_equal 2, DeployEvent.count
  end

  test "一次缓慢但正常的部署——pre 之后 16 分钟才到的 succeeded 仍配到同一行" do
    started = ingest("started")[:event]
    started.update!(started_at: 16.minutes.ago)

    result = ingest("succeeded")

    assert_equal started.id, result[:event].id
    assert result[:changed]
    assert_predicate result[:event].succeeded_at, :present?
    assert_equal 1, DeployEvent.count
  end

  test "推断行不会把随后到达的 post-deploy 上报吞成重复" do
    DeployEvent.create!(managed_app: @app, version: "aaaaaaa", source: "inferred",
                        succeeded_at: 10.seconds.ago, observed_at: 10.seconds.ago)

    result = ingest("succeeded", version: "aaaaaaa")

    assert_equal 2, DeployEvent.count
    assert result[:changed]
    assert_equal "ci", result[:event].performer
    assert_equal "hook", result[:event].source
  end

  test "recorded_at 照存不误，但 started_at 用服务端时刻" do
    lie = 1.hour.from_now
    event = ingest("started", recorded_at: lie)[:event]

    assert_in_delta lie, event.recorded_at, 1.second
    assert_operator event.started_at, :<, 1.minute.from_now
  end
end
