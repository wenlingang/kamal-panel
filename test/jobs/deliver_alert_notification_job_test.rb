require "test_helper"

class DeliverAlertNotificationJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Rails.cache.clear
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production")
    @rule = AlertRule.create!(name: "不健康", condition: "unhealthy")
    @event = AlertEvent.create!(alert_rule: @rule, managed_app: @app, state: "firing", message_key: "unhealthy",
                                started_at: 3.minutes.ago, fired_at: 1.minute.ago)
    @channel = NotificationChannel.create!(name: "hook", kind: "webhook", target: "https://hooks.example.com/x")
  end

  test "records a delivery" do
    stub_http("POST https://hooks.example.com/x" => [ 200 ]) do
      DeliverAlertNotificationJob.perform_now(@event, @channel, "firing")
    end

    assert @channel.reload.last_delivered_at
    assert_nil @channel.last_error
  end

  test "records a failure on the channel and retries" do
    stub_http("POST https://hooks.example.com/x" => [ 500, "boom" ]) do
      assert_enqueued_with(job: DeliverAlertNotificationJob) do
        DeliverAlertNotificationJob.perform_now(@event, @channel, "firing")
      end
    end

    assert_includes @channel.reload.last_error, "500"
  end

  test "a channel disabled since the job was queued is skipped" do
    @channel.update!(enabled: false)

    stub_http({}) { DeliverAlertNotificationJob.perform_now(@event, @channel, "firing") }

    assert_nil @channel.reload.last_delivered_at
  end
end
