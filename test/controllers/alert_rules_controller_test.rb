require "test_helper"

class AlertRulesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @managed_app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production")
    @channel = NotificationChannel.create!(name: "hook", kind: "webhook", target: "https://hooks.example.com/x")
    @rule = AlertRule.create!(name: "漂移", condition: "drift")
  end

  test "non-admins can't add, edit or delete rules" do
    [ users(:one), users(:three) ].each do |user|
      sign_in_as user

      get new_alert_rule_path
      assert_redirected_to root_path
      get edit_alert_rule_path(@rule)
      assert_redirected_to root_path
      assert_no_difference -> { AlertRule.count } do
        post alert_rules_path, params: { alert_rule: { name: "x", condition: "drift" } }
      end
      patch alert_rule_path(@rule), params: { alert_rule: { name: "hijacked" } }
      delete alert_rule_path(@rule)
      assert_redirected_to root_path
    end

    assert_equal "漂移", @rule.reload.name
  end

  test "admin adds a log rule with channels; it is audited" do
    sign_in_as users(:two)

    get new_alert_rule_path
    assert_response :success
    assert_select "[data-controller=alert-rule-form]"

    post alert_rules_path, params: { alert_rule: {
      name: "错误日志", condition: "log_keyword", managed_app_id: @managed_app.id, keyword: "ERROR",
      window_minutes: "10", threshold: "5", log_source: "", for_minutes: "0", enabled: "1",
      notification_channel_ids: [ "", @channel.id.to_s ]
    } }

    assert_redirected_to alert_rules_path
    rule = AlertRule.find_by!(name: "错误日志")
    assert_equal [ 10, 5, "app" ], [ rule.window_minutes, rule.threshold, rule.log_source ]
    assert_equal [ @channel ], rule.notification_channels
    assert AuditLog.exists?(action_name: "alert_rule.create", detail: "错误日志", managed_app_id: @managed_app.id)
  end

  test "an invalid rule re-renders the form" do
    sign_in_as users(:two)

    post alert_rules_path, params: { alert_rule: { name: "bad", condition: "log_keyword", keyword: "" } }

    assert_response :unprocessable_entity
  end

  test "admin edits and deletes; both audited" do
    sign_in_as users(:two)

    patch alert_rule_path(@rule), params: { alert_rule: { name: "版本漂移", for_minutes: "5", notification_channel_ids: [ "" ] } }
    assert_equal [ "版本漂移", 5 ], [ @rule.reload.name, @rule.for_minutes ]
    assert AuditLog.exists?(action_name: "alert_rule.update")

    delete alert_rule_path(@rule)
    assert_not AlertRule.exists?(@rule.id)
    assert AuditLog.exists?(action_name: "alert_rule.delete", detail: "版本漂移")
  end

  test "admin adds a resource rule; the form has its own threshold field, shown only for those conditions" do
    sign_in_as users(:two)

    get new_alert_rule_path
    assert_select "fieldset[data-conditions=?] input[name=?]", AlertRule::METRIC_CONDITIONS.join(" "), "alert_rule[metric_threshold]"
    assert_select "select[name=?] option[value=host_disk_high]", "alert_rule[condition]"

    post alert_rules_path, params: { alert_rule: { name: "磁盘", condition: "host_disk_high", for_minutes: 5,
                                                   threshold: "", metric_threshold: "85" } }

    rule = AlertRule.find_by!(name: "磁盘")
    assert_equal 85, rule.metric_threshold
    get alert_rules_path
    assert_select "td", text: /≥ 85%/
  end
end
