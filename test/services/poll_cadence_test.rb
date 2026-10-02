require "test_helper"

class PollCadenceTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(
      name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )
    Rails.cache.clear
  end

  test "60 seconds by default when nobody is viewing" do
    assert_equal 60.seconds, PollCadence.interval_for(@app)
  end

  test "10 seconds when someone is viewing" do
    PollCadence.mark_viewed!(@app)

    assert_equal 10.seconds, PollCadence.interval_for(@app)
  end

  test "2 seconds during a burst" do
    PollCadence.mark_burst!(@app)

    assert_equal 2.seconds, PollCadence.interval_for(@app)
  end

  test "falls back 90 seconds after a burst" do
    PollCadence.mark_burst!(@app)

    travel 91.seconds do
      assert_equal 60.seconds, PollCadence.interval_for(@app)
    end
  end

  test "burst takes priority over viewing" do
    PollCadence.mark_viewed!(@app)
    PollCadence.mark_burst!(@app)

    assert_equal 2.seconds, PollCadence.interval_for(@app)
  end
end
