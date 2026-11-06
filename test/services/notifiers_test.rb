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

  test "the message is in the default locale and links back to the app" do
    I18n.with_locale(:en) do
      assert_equal "[告警] 不健康 · blog", firing_message.title
    end
    assert_equal "https://panel.example.com/apps/#{@app.id}", firing_message.url
  end

  test "without PANEL_URL there is no link rather than a guessed one" do
    Rails.application.config.x.panel_url = nil

    assert_nil firing_message.url
  end

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

  test "webhook without a secret sends no signature; a 5xx is a failure with the reason" do
    hook = channel("webhook")

    stub_http("POST https://hooks.example.com/t0ken" => [ 503, "<html>down for maintenance</html>" ]) do |calls|
      result = hook.deliver(firing_message)
      assert_not result.ok?
      assert_includes result.error, "503"
      assert_nil calls.sole[:headers]["x-kamal-panel-signature"]
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

  test "feishu sends text and signs timestamp + secret the way Feishu documents it" do
    bot = channel("feishu", target: "https://open.feishu.cn/open-apis/bot/v2/hook/abc", secret: "feishu-secret")

    travel_to Time.at(1_700_000_000) do
      stub_http("POST https://open.feishu.cn/open-apis/bot/v2/hook/abc" => [ 200, { code: 0, msg: "success" } ]) do |calls|
        assert_predicate bot.deliver(firing_message), :ok?

        payload = JSON.parse(calls.sole[:body])
        assert_equal "text", payload["msg_type"]
        assert_includes payload["content"]["text"], "[告警] 不健康 · blog"
        assert_equal "1700000000", payload["timestamp"]
        expected = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", "1700000000\nfeishu-secret", ""))
        assert_equal expected, payload["sign"]
      end
    end
  end

  test "feishu refuses with HTTP 200 and a non-zero code; that is a failure" do
    bot = channel("feishu", target: "https://open.feishu.cn/open-apis/bot/v2/hook/abc")

    stub_http("POST https://open.feishu.cn/open-apis/bot/v2/hook/abc" => [ 200, { code: 19021, msg: "sign match fail" } ]) do |calls|
      result = bot.deliver(firing_message)
      assert_not result.ok?
      assert_includes result.error, "sign match fail"
      assert_nil JSON.parse(calls.sole[:body])["sign"], "no secret, no signature"
    end
  end

  test "slack posts text and a section block, escaping mrkdwn control characters" do
    @app.update_columns(name: "a<b>&c")
    slack = channel("slack", target: "https://hooks.slack.com/services/T/B/x")

    stub_http("POST https://hooks.slack.com/services/T/B/x" => [ 200, "ok" ]) do |calls|
      assert_predicate slack.deliver(Notifiers::Message.for_event(@event.reload, "resolved")), :ok?

      payload = JSON.parse(calls.sole[:body])
      assert_includes payload["text"], "[已恢复] 不健康 · a<b>&c"
      assert_includes payload["blocks"].first["text"]["text"], "a&lt;b&gt;&amp;c"
    end

    # Only the status comes back: the body of whatever answered at an admin-entered URL is never
    # echoed into the UI (it could be an internal page).
    stub_http("POST https://hooks.slack.com/services/T/B/x" => [ 404, "no_service" ]) do
      assert_equal "HTTP 404", slack.deliver(firing_message).error
    end
  end

  test "email goes through AlertMailer to every recipient" do
    mail = channel("email", target: "a@example.com, b@example.com")

    assert_difference -> { ActionMailer::Base.deliveries.size } do
      assert_predicate mail.deliver(firing_message), :ok?
    end
    assert_equal %w[a@example.com b@example.com], ActionMailer::Base.deliveries.last.to
  end

  test "the test message names the channel" do
    hook = channel("webhook")
    test_message = Notifiers::Message.test(hook)

    assert_equal "test", test_message.as_payload[:event]
    assert_includes test_message.body, hook.name
  end
end
