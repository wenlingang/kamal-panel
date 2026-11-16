require "test_helper"

class AttentionItemsTest < ActiveSupport::TestCase
  setup do
    @admin = User.create!(email_address: "admin@example.com", password: "secret123456", role: "admin")
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("accessory_deploy.yml").read, destination: "production")
  end

  test "names what won't fix itself, worst first" do
    destination = BackupDestination.create!(name: "s3", endpoint: "https://s3.example.com", bucket: "backups",
                                            access_key_id: "k", secret_access_key: "s")
    plan = @app.backup_plans.create!(accessory: "db", engine: "postgres", backup_destination: destination)
    plan.backup_runs.create!(managed_app: @app, state: "failed", error: "x", started_at: 1.hour.ago, finished_at: 1.hour.ago)

    keys = AttentionItems.new(@admin).items.map(&:key)
    assert_equal "backup_failed:#{plan.id}", keys.first
    assert_includes keys, "no_ssh_key:#{@app.id}"
    assert_includes keys, "no_alert_rules"
  end

  test "a dismissed item stays hidden until the problem starts again" do
    item = AttentionItems.new(@admin).items.find { |i| i.key == "no_ssh_key:#{@app.id}" }
    DismissedIssue.create!(issue_key: item.key, since: item.since)
    assert_not_includes AttentionItems.new(@admin).items.map(&:key), item.key

    @app.update_column(:created_at, 1.minute.from_now)
    assert_includes AttentionItems.new(@admin).items.map(&:key), item.key
  end

  test "settings problems are for admins only" do
    ops = User.create!(email_address: "ops@example.com", password: "secret123456", role: "ops")
    assert_not_includes AttentionItems.new(ops).items.map(&:key), "no_alert_rules"
  end
end
