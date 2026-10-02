require "test_helper"

class DeployEventTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  def event(**attrs)
    DeployEvent.create!({ managed_app: @app, version: "aaaaaaa", source: "hook" }.merge(attrs))
  end

  test "says unverified when observed but no success report yet, not observed before report" do
    e = event(observed_at: 1.minute.ago)

    assert_equal "未验证", e.observation_delay_text
  end

  test "observed before the report when succeeded_at is after observed_at" do
    e = event(observed_at: 10.minutes.ago, succeeded_at: 5.minutes.ago)

    assert_equal "上报前已观测到", e.observation_delay_text
  end

  test "shows delay seconds when observed_at is after succeeded_at" do
    e = event(succeeded_at: 10.minutes.ago, observed_at: 9.minutes.ago)

    assert_match(/延迟 \d+ 秒/, e.observation_delay_text)
  end

  test "is nil when not yet observed, leaving the caller to show unverified" do
    e = event(succeeded_at: 1.minute.ago)

    assert_nil e.observation_delay_text
  end

  test "does not state a delay in the observation column for inferred events" do
    at = 5.minutes.ago
    event = DeployEvent.new(source: "inferred", version: "aaaaaaa",
                            succeeded_at: at, observed_at: at)

    assert_equal "面板观测到", event.observation_delay_text,
                 "An inferred event has no report, so the computed 0 seconds is a meaningless number"
  end

  test "source has a text label" do
    assert_equal "hook 上报", DeployEvent.new(source: "hook").source_text
    assert_equal "面板推断", DeployEvent.new(source: "inferred").source_text
  end
end
