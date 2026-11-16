require "test_helper"

class AlertSilenceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production")
    @other = ManagedApp.create!(name: "shop", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production")
  end

  test "an app's silence covers that app, a global one covers every app, and only while it runs" do
    now = Time.current
    AlertSilence.create!(managed_app: @app, starts_at: now - 1.minute, ends_at: now + 1.hour)

    assert AlertSilence.silenced?(@app.id, now)
    assert_not AlertSilence.silenced?(@other.id, now)
    assert_not AlertSilence.silenced?(@app.id, now + 2.hours)

    AlertSilence.create!(starts_at: now + 1.day)
    assert_not AlertSilence.silenced?(@other.id, now), "a planned silence hasn't started"
    assert AlertSilence.silenced?(@other.id, now + 1.day + 1.minute)
  end

  test "maintenance mode silences until the app goes live, once" do
    AlertSilence.start_maintenance!(@app, nil)
    AlertSilence.start_maintenance!(@app, nil)
    assert_equal 1, AlertSilence.active.count
    assert AlertSilence.silenced?(@app.id)

    AlertSilence.end_maintenance!(@app)
    assert_not AlertSilence.silenced?(@app.id)
  end

  test "an end before the start is refused" do
    silence = AlertSilence.new(starts_at: Time.current, ends_at: 1.hour.ago)
    assert_not silence.valid?
  end

  test "notifications are held during a silence, not the event" do
    channel = NotificationChannel.create!(name: "hook", kind: "webhook", target: "https://hooks.example.com/x")
    rule = AlertRule.create!(name: "x", condition: "unhealthy", for_minutes: 0, notification_channels: [ channel ])
    event = AlertEvent.create!(alert_rule: rule, managed_app: @app, state: "firing", message_key: "unhealthy", started_at: Time.current)

    AlertSilence.create!(managed_app: @app, starts_at: 1.minute.ago, ends_at: 1.hour.from_now)
    assert_no_enqueued_jobs(only: DeliverAlertNotificationJob) { Alerting::Notification.enqueue(event, "firing") }

    AlertSilence.update_all(ends_at: 1.second.ago)
    assert_enqueued_jobs(1, only: DeliverAlertNotificationJob) { Alerting::Notification.enqueue(event, "firing") }
  end
end
