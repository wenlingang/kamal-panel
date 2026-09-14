require "test_helper"

class PollCadenceTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(
      name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )
    Rails.cache.clear
  end

  test "默认无人查看时 60 秒" do
    assert_equal 60.seconds, PollCadence.interval_for(@app)
  end

  test "有人正在查看时 10 秒" do
    PollCadence.mark_viewed!(@app)

    assert_equal 10.seconds, PollCadence.interval_for(@app)
  end

  test "burst 期间 2 秒" do
    PollCadence.mark_burst!(@app)

    assert_equal 2.seconds, PollCadence.interval_for(@app)
  end

  test "burst 90 秒后回落" do
    PollCadence.mark_burst!(@app)

    travel 91.seconds do
      assert_equal 60.seconds, PollCadence.interval_for(@app)
    end
  end

  test "burst 优先于 viewing" do
    PollCadence.mark_viewed!(@app)
    PollCadence.mark_burst!(@app)

    assert_equal 2.seconds, PollCadence.interval_for(@app)
  end
end
