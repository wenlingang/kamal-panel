require "test_helper"

# Every page the newer features added renders for an admin (forms included), so a template error
# can't hide behind a page no other test opens.
class NewPagesRenderTest < ActionDispatch::IntegrationTest
  setup do
    @managed_app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("accessory_deploy.yml").read, destination: "production")
    @destination = BackupDestination.create!(name: "s3", endpoint: "https://s3.example.com", bucket: "backups",
                                             access_key_id: "k", secret_access_key: "s", last_check_error: "HTTP 403",
                                             last_checked_at: Time.current)
    @plan = @managed_app.backup_plans.create!(accessory: "db", engine: "postgres", backup_destination: @destination)
    @channel = NotificationChannel.create!(name: "hook", kind: "webhook", target: "https://hooks.example.com/x")
    @rule = AlertRule.create!(name: "证书", condition: "cert_expiring", for_minutes: 0, days: 10)
    sign_in_as users(:two)
  end

  test "settings, forms and lists render" do
    [
      backup_destinations_path, new_backup_destination_path, edit_backup_destination_path(@destination),
      new_managed_app_backup_plan_path(@managed_app), edit_managed_app_backup_plan_path(@managed_app, @plan),
      managed_app_path(@managed_app, tab: "backups"), managed_app_path(@managed_app, tab: "deploy"),
      edit_managed_app_path(@managed_app),
      alert_silences_path, new_alert_silence_path(managed_app_id: @managed_app.id),
      new_alert_rule_path, edit_alert_rule_path(@rule), alert_rules_path,
      edit_notification_channel_path(@channel), overview_path
    ].each do |path|
      get path
      assert_response :success, "GET #{path}"
    end
  end
end
