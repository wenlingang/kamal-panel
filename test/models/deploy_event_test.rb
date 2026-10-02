require "test_helper"

class DeployEventTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  def event(**attrs)
    DeployEvent.create!({ managed_app: @app, version: "aaaaaaa", source: "hook" }.merge(attrs))
  end

  test "已观测但还没收到成功上报时说未验证，不能说成上报前已观测到" do
    e = event(observed_at: 1.minute.ago)

    assert_equal "未验证", e.observation_delay_text
  end

  test "上报前已观测到——succeeded_at 在 observed_at 之后" do
    e = event(observed_at: 10.minutes.ago, succeeded_at: 5.minutes.ago)

    assert_equal "上报前已观测到", e.observation_delay_text
  end

  test "延迟秒数——observed_at 在 succeeded_at 之后" do
    e = event(succeeded_at: 10.minutes.ago, observed_at: 9.minutes.ago)

    assert_match(/延迟 \d+ 秒/, e.observation_delay_text)
  end

  test "还没观测到就是 nil，交给调用方显示未验证" do
    e = event(succeeded_at: 1.minute.ago)

    assert_nil e.observation_delay_text
  end

  test "推断事件的观测列不说延迟" do
    at = 5.minutes.ago
    event = DeployEvent.new(source: "inferred", version: "aaaaaaa",
                            succeeded_at: at, observed_at: at)

    assert_equal "面板观测到", event.observation_delay_text,
                 "推断事件没有上报，算出来的 0 秒是个没有含义的数字"
  end

  test "来源有文字说法" do
    assert_equal "hook 上报", DeployEvent.new(source: "hook").source_text
    assert_equal "面板推断", DeployEvent.new(source: "inferred").source_text
  end
end
