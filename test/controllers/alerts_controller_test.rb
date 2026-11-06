require "test_helper"

class AlertsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @managed_app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production")
    @rule = AlertRule.create!(name: "不健康规则", condition: "unhealthy")
    @firing = AlertEvent.create!(alert_rule: @rule, managed_app: @managed_app, state: "firing", message_key: "unhealthy",
                                 started_at: 10.minutes.ago, fired_at: 8.minutes.ago)
    AlertEvent.create!(alert_rule: @rule, managed_app: @managed_app, state: "resolved", message_key: "drift",
                       message_args: { versions: "a, b" }, started_at: 2.hours.ago, fired_at: 2.hours.ago,
                       resolved_at: 1.hour.ago)
  end

  test "everyone signed in sees what is firing and the history" do
    [ users(:one), users(:two), users(:three) ].each do |user|
      sign_in_as user
      get alerts_path

      assert_response :success
      assert_select ".alert-item", count: 1 do
        assert_select "a", text: "blog"
      end
      assert_match I18n.t("alert_events.messages.unhealthy"), response.body
      assert_match "a, b", response.body
    end
  end

  test "the sidebar badge counts firing alerts" do
    sign_in_as users(:three)
    get root_path

    assert_select "nav.side-nav a[href=?] .side-nav-badge", alerts_path, text: "1"
    assert_select ".strip-alerts .strip-count", text: "1"
  end

  test "the app page shows its firing alerts" do
    sign_in_as users(:two)
    get managed_app_path(@managed_app)

    assert_select "#app-alerts .firing-alerts", text: /不健康规则/
  end

  test "history filters by state" do
    sign_in_as users(:one)
    get alerts_path(state: "resolved")

    assert_select "table tbody tr", count: 1
  end

  test "only admins get the edit entry points" do
    sign_in_as users(:three)
    get alert_rules_path
    assert_response :success
    assert_match "不健康规则", response.body
    assert_select "a[href=?]", edit_alert_rule_path(@rule), count: 0
    assert_select "a[href=?]", new_alert_rule_path, count: 0

    sign_in_as users(:two)
    get alert_rules_path
    assert_select "a[href=?]", edit_alert_rule_path(@rule)
  end

  test "the channels tab is readable by everyone and masks the target" do
    NotificationChannel.create!(name: "值班群", kind: "slack", target: "https://hooks.slack.com/services/T/B/secret-token")
    sign_in_as users(:one)

    get alert_channels_path

    assert_response :success
    assert_match "值班群", response.body
    assert_no_match "secret-token", response.body
    assert_select "button", text: I18n.t("notification_channels.table.test"), count: 0
  end

  # Missing English strings only show when a page actually renders under :en (zh-CN falls back
  # silently the other way round).
  test "every alerting page renders in English" do
    users(:two).update!(locale: "en")
    NotificationChannel.create!(name: "hook", kind: "webhook", target: "https://hooks.example.com/x")
    sign_in_as users(:two)

    [ alerts_path, alert_rules_path, alert_channels_path, new_alert_rule_path, edit_alert_rule_path(@rule),
      notification_channels_path, new_notification_channel_path, managed_app_path(@managed_app), root_path ].each do |path|
      get path
      assert_response :success, path
    end

    get alerts_path
    assert_match "Firing (1)", response.body
  end
end
