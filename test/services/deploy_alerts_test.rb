require "test_helper"

class DeployAlertsTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  def event(**attrs)
    DeployEvent.create!({ managed_app: @app, version: "aaaaaaa", source: "hook" }.merge(attrs))
  end

  test "alerts when still unobserved 91 seconds after a reported success" do
    event(succeeded_at: 91.seconds.ago)

    alert = DeployAlerts.new(@app).list.sole

    assert_equal :unobserved, alert[:kind]
    assert_match "aaaaaaa", alert[:message]
    assert_match "未在任何机器上观测到", alert[:message]
  end

  test "does not alert at 89 seconds -- the next polling round simply has not come yet" do
    event(succeeded_at: 89.seconds.ago)

    assert_empty DeployAlerts.new(@app).list
  end

  test "does not alert once observed" do
    event(succeeded_at: 10.minutes.ago, observed_at: 9.minutes.ago)

    assert_empty DeployAlerts.new(@app).list
  end

  test "alerts when started 16 minutes ago with no completion" do
    event(started_at: 16.minutes.ago)

    alert = DeployAlerts.new(@app).list.sole

    assert_equal :unfinished, alert[:kind]
    assert_match "至今未收到完成上报", alert[:message]
  end

  test "does not alert at 14 minutes since start -- a normal deploy takes that long" do
    event(started_at: 14.minutes.ago)

    assert_empty DeployAlerts.new(@app).list
  end

  test "a completed deploy no longer counts as started without completion" do
    event(started_at: 30.minutes.ago, succeeded_at: 29.minutes.ago, observed_at: 29.minutes.ago)

    assert_empty DeployAlerts.new(@app).list
  end

  test "an unobserved success event from 25 hours ago no longer alerts -- it is history, not news" do
    event(succeeded_at: 25.hours.ago, created_at: 25.hours.ago)

    assert_empty DeployAlerts.new(@app).list
  end

  test "once a newer observed event appears, the old contradiction is dropped" do
    stale = event(succeeded_at: 20.minutes.ago, created_at: 20.minutes.ago)
    event(version: "bbbbbbb", succeeded_at: 10.minutes.ago, observed_at: 5.minutes.ago,
          created_at: 10.minutes.ago)

    assert_empty DeployAlerts.new(@app).list
    assert_nil stale.reload.observed_at, "the event row itself should remain in history, not be erased"
  end

  # not_superseded uses the "created_at of the latest observed event" as the cutoff. Inferred rows
  # are inherently observed (a row with source: "inferred" always has observed_at), so it also turns
  # the page on earlier hook alerts that haven't been observed yet -- this is intentional: an
  # inferred row is evidence backed by observation, harder than a report that was never observed, so
  # there's no reason to keep clinging to that report's contradiction. The spec only says "inferred
  # events don't trigger alerts", not "they resolve them", so this pins that behavior.
  test "an inferred row resolves an earlier hook alert that was not yet observed" do
    stale = event(succeeded_at: 20.minutes.ago, created_at: 20.minutes.ago)
    assert_equal :unobserved, DeployAlerts.new(@app).list.sole[:kind], "first confirm the alert existed to begin with"

    DeployEvent.create!(managed_app: @app, version: "bbbbbbb", source: "inferred",
                        succeeded_at: 1.minute.ago, observed_at: 1.minute.ago,
                        created_at: 1.minute.ago)

    assert_empty DeployAlerts.new(@app).list
    assert_nil stale.reload.observed_at, "being resolved is not being erased; the event row itself should remain in history"
  end

  test "the two alert kinds have different semantics and each gets its own entry when both exist" do
    event(succeeded_at: 5.minutes.ago)
    event(version: "bbbbbbb", started_at: 30.minutes.ago)

    kinds = DeployAlerts.new(@app).list.map { |a| a[:kind] }

    assert_equal [ :unobserved, :unfinished ], kinds.sort_by(&:to_s).reverse
  end
end
