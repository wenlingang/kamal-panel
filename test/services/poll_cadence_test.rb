require "test_helper"

class PollCadenceTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(
      name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )
    Rails.cache.clear
  end

  test "burst takes priority over viewing" do
    PollCadence.mark_viewed!(@app)
    PollCadence.mark_burst!(@app)

    assert_equal PollCadence::BURST, PollCadence.interval_for(@app)
  end

  # A slot held for the full interval expires on the very tick the app falls due, and whether that
  # tick sees it expired is a race; held a little shorter, it is always free again by then.
  test "a claimed slot is released before the tick on which the app falls due" do
    [ nil, :viewed, :burst ].each do |mode|
      Rails.cache.clear
      PollCadence.mark_viewed!(@app) if mode == :viewed
      PollCadence.mark_burst!(@app) if mode == :burst

      ttl = PollCadence.slot_ttl_for(@app)
      interval = PollCadence.interval_for(@app)
      assert_operator ttl, :<, interval
      assert_operator ttl, :>, interval - PollCadence::TICK, "the slot must still block the tick before"
    end
  end

  test "no cadence is faster than the scheduler tick" do
    assert_operator PollCadence::BURST, :>=, PollCadence::TICK
  end
end
