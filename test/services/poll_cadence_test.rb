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

    assert_equal PollCadence.burst, PollCadence.interval_for(@app)
  end

  # The slot is claimed when the scheduler job runs, which trails its tick by a jittery delay; half a
  # tick of margin on both sides keeps a late claim from making the app skip its due tick.
  test "a claimed slot leaves half a tick of margin on either side" do
    [ nil, :viewed, :burst ].each do |mode|
      Rails.cache.clear
      PollCadence.mark_viewed!(@app) if mode == :viewed
      PollCadence.mark_burst!(@app) if mode == :burst

      ttl = PollCadence.slot_ttl_for(@app)
      interval = PollCadence.interval_for(@app)
      assert_equal interval - PollCadence.tick / 2.0, ttl
    end
  end

  test "turning viewed or bursting releases a slot claimed at the slower cadence" do
    claim = -> { Rails.cache.write(PollCadence.last_run_key(@app), Time.current, expires_in: PollCadence.slot_ttl_for(@app), unless_exist: true) }

    assert claim.call, "idle app claims a slot held for most of a minute"
    PollCadence.mark_viewed!(@app)
    assert claim.call, "becoming viewed frees it, so the next tick polls"

    PollCadence.mark_viewed!(@app)
    refute claim.call, "a renewal while already viewed must not free the slot again"

    PollCadence.mark_burst!(@app)
    assert claim.call, "a burst frees it too"
  end

  test "no cadence is faster than the scheduler tick" do
    assert_operator PollCadence.burst, :>=, PollCadence.tick
  end
end
