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
end
