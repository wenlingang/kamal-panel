require "test_helper"

class NotifiersTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production")
    @rule = AlertRule.create!(name: "不健康", condition: "unhealthy")
    @event = AlertEvent.create!(alert_rule: @rule, managed_app: @app, state: "firing", message_key: "unhealthy",
                                started_at: Time.utc(2026, 11, 5, 8, 0), fired_at: Time.utc(2026, 11, 5, 8, 2))
    @previous_url = Rails.application.config.x.panel_url
    Rails.application.config.x.panel_url = "https://panel.example.com"
  end

  teardown { Rails.application.config.x.panel_url = @previous_url }

  def channel(kind, target: "https://hooks.example.com/t0ken", secret: nil)
    NotificationChannel.create!(name: "#{kind}-#{SecureRandom.hex(2)}", kind:, target:, secret:)
  end

  def firing_message = Notifiers::Message.for_event(@event, "firing")

  test "webhook posts the JSON payload, signed when there is a secret" do
    hook = channel("webhook", secret: "shh")

    stub_http("POST https://hooks.example.com/t0ken" => [ 204 ]) do |calls|
      assert_predicate hook.deliver(firing_message), :ok?

      body = calls.sole[:body]
      payload = JSON.parse(body)
      assert_equal "alert.firing", payload["event"]
      assert_equal "firing", payload["state"]
      assert_equal({ "id" => @rule.id, "name" => "不健康", "condition" => "unhealthy" }, payload["rule"])
      assert_equal({ "id" => @app.id, "name" => "blog" }, payload["app"])
      assert_equal "2026-11-05T08:00:00Z", Time.iso8601(payload["started_at"]).utc.iso8601
      assert_equal "https://panel.example.com/apps/#{@app.id}", payload["url"]
      assert_equal "application/json", calls.sole[:headers]["content-type"]
      assert_equal "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', 'shh', body)}", calls.sole[:headers]["x-kamal-panel-signature"]
    end
  end

  test "a network failure is a failed result, not an exception" do
    hook = channel("webhook")

    stub_http("POST https://hooks.example.com/t0ken" => Errno::ECONNREFUSED) do
      result = hook.deliver(firing_message)
      assert_not result.ok?
      assert_includes result.error, "ECONNREFUSED"
    end
  end
end
