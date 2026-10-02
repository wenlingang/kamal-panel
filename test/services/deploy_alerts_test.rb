require "test_helper"

class DeployAlertsTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  def event(**attrs)
    DeployEvent.create!({ managed_app: @app, version: "aaaaaaa", source: "hook" }.merge(attrs))
  end

  test "上报成功 91 秒仍未观测到就告警" do
    event(succeeded_at: 91.seconds.ago)

    alert = DeployAlerts.new(@app).list.sole

    assert_equal :unobserved, alert[:kind]
    assert_match "aaaaaaa", alert[:message]
    assert_match "未在任何机器上观测到", alert[:message]
  end

  test "89 秒还不告警——那只是还没轮到下一轮轮询" do
    event(succeeded_at: 89.seconds.ago)

    assert_empty DeployAlerts.new(@app).list
  end

  test "观测到了就不告警" do
    event(succeeded_at: 10.minutes.ago, observed_at: 9.minutes.ago)

    assert_empty DeployAlerts.new(@app).list
  end

  test "开了头 16 分钟没收尾就告警" do
    event(started_at: 16.minutes.ago)

    alert = DeployAlerts.new(@app).list.sole

    assert_equal :unfinished, alert[:kind]
    assert_match "至今未收到完成上报", alert[:message]
  end

  test "开了头 14 分钟不告警——一次正常部署本来就要这么久" do
    event(started_at: 14.minutes.ago)

    assert_empty DeployAlerts.new(@app).list
  end

  test "已收尾的不再算作开了头没收尾" do
    event(started_at: 30.minutes.ago, succeeded_at: 29.minutes.ago, observed_at: 29.minutes.ago)

    assert_empty DeployAlerts.new(@app).list
  end

  test "25 小时前的未观测成功事件不再告警——那是历史，不是现在需要看一眼的事" do
    event(succeeded_at: 25.hours.ago, created_at: 25.hours.ago)

    assert_empty DeployAlerts.new(@app).list
  end

  test "出现更新的已观测事件之后，旧的矛盾就翻篇了" do
    stale = event(succeeded_at: 20.minutes.ago, created_at: 20.minutes.ago)
    event(version: "bbbbbbb", succeeded_at: 10.minutes.ago, observed_at: 5.minutes.ago,
          created_at: 10.minutes.ago)

    assert_empty DeployAlerts.new(@app).list
    assert_nil stale.reload.observed_at, "历史里那行事件本身还留着痕迹，不是被抹掉"
  end

  # not_superseded 用"最近一条已观测事件的 created_at"当截止线。推断行
  # 天生已观测（source: "inferred" 的行 observed_at 必有值），所以它会把
  # 更早的、尚未被观测到的 hook 告警一并翻篇——这是有意为之：推断行是
  # 观测背书的证据，比一条始终没被观测到的上报更硬，没道理还揪着那条
  # 上报的矛盾不放。spec 只写了"推断事件不触发告警"，没写"会消解"，
  # 这里把这条行为钉住。
  test "推断行会消解更早的、尚未被观测到的 hook 告警" do
    stale = event(succeeded_at: 20.minutes.ago, created_at: 20.minutes.ago)
    assert_equal :unobserved, DeployAlerts.new(@app).list.sole[:kind], "先确认告警本来是存在的"

    DeployEvent.create!(managed_app: @app, version: "bbbbbbb", source: "inferred",
                        succeeded_at: 1.minute.ago, observed_at: 1.minute.ago,
                        created_at: 1.minute.ago)

    assert_empty DeployAlerts.new(@app).list
    assert_nil stale.reload.observed_at, "被消解不等于被抹掉，历史里那行事件本身还留着痕迹"
  end

  test "两类告警语义不同，同时存在时各占一条" do
    event(succeeded_at: 5.minutes.ago)
    event(version: "bbbbbbb", started_at: 30.minutes.ago)

    kinds = DeployAlerts.new(@app).list.map { |a| a[:kind] }

    assert_equal [ :unobserved, :unfinished ], kinds.sort_by(&:to_s).reverse
  end
end
