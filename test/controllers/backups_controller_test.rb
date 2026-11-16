require "test_helper"

class BackupsControllerTest < ActionDispatch::IntegrationTest
  include HttpStub
  include ActiveJob::TestHelper

  setup do
    @managed_app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("accessory_deploy.yml").read, destination: "production")
  end

  def sign_in(role)
    User.create!(email_address: "#{role}@example.com", password: "secret123456", role:)
    post session_path, params: { email_address: "#{role}@example.com", password: "secret123456" }
  end

  def destination
    @destination ||= BackupDestination.create!(name: "r2", endpoint: "https://acct.r2.cloudflarestorage.com", region: "auto",
                                               bucket: "backups", access_key_id: "key", secret_access_key: "secret")
  end

  test "admin adds storage, and saving checks it right away" do
    sign_in("admin")

    stub_http(%r{\APUT https://acct\.r2\.cloudflarestorage\.com/backups/\.kamal-panel-check\z} => [ 200, "" ],
              %r{\ADELETE https://acct\.r2\.cloudflarestorage\.com/backups/\.kamal-panel-check\z} => [ 204, "" ]) do
      post backup_destinations_path, params: { backup_destination: {
        name: "r2", endpoint: "https://acct.r2.cloudflarestorage.com/", region: "auto", bucket: "backups",
        access_key_id: "key", secret_access_key: "secret", path_style: "1" } }
    end

    assert_redirected_to backup_destinations_path
    assert_match I18n.t("flash.backup_destination.check_ok", name: "r2"), flash[:notice]
    assert_equal "https://acct.r2.cloudflarestorage.com", BackupDestination.sole.endpoint
    assert_equal "backup_destination.create", AuditLog.last.action_name
  end

  test "storage settings are admin only" do
    sign_in("developer")
    get backup_destinations_path
    assert_redirected_to root_path
  end

  test "the backups tab offers the database accessories and shows the restore command" do
    sign_in("admin")
    plan = @managed_app.backup_plans.create!(accessory: "db", engine: "postgres", backup_destination: destination)
    plan.backup_runs.create!(managed_app: @managed_app, state: "failed", error: "Authentication failed for user deploy",
                             diagnosis: FailureDiagnosis.call("Authentication failed for user deploy"),
                             started_at: 1.hour.ago, finished_at: 1.hour.ago)

    get managed_app_path(@managed_app, tab: "backups")

    assert_response :success
    assert_select ".backup-plan h3", text: "db"
    assert_select ".backup-failure", text: /#{Regexp.escape(I18n.t("failure_diagnosis.ssh_auth.cause", user: "deploy"))}/
    assert_select ".backup-command code", text: /docker exec -i blog-db/
  end

  test "setting up and running a backup is audited and queued" do
    sign_in("admin")

    post managed_app_backup_plans_path(@managed_app), params: { backup_plan: {
      accessory: "db", engine: "postgres", backup_destination_id: destination.id, every_hours: 24, keep: 7, enabled: "1" } }
    plan = @managed_app.backup_plans.sole
    assert_redirected_to managed_app_path(@managed_app, tab: "backups")

    assert_enqueued_with(job: RunBackupJob) do
      post run_managed_app_backup_plan_path(@managed_app, plan)
    end
    assert_equal %w[backup_plan.create backup.run], AuditLog.order(:id).last(2).map(&:action_name)
  end

  test "a download is a short-lived signed link, for people who may act on the app only" do
    plan = @managed_app.backup_plans.create!(accessory: "db", engine: "postgres", backup_destination: destination)
    run = plan.backup_runs.create!(managed_app: @managed_app, state: "succeeded", object_key: "blog/db/x.sql.gz",
                                   started_at: 1.hour.ago, finished_at: 1.hour.ago)

    sign_in("ops")
    get download_managed_app_backup_run_path(@managed_app, run)
    assert_redirected_to root_path

    delete session_path
    sign_in("admin")
    get download_managed_app_backup_run_path(@managed_app, run)
    assert_match %r{\Ahttps://acct\.r2\.cloudflarestorage\.com/backups/blog/db/x\.sql\.gz\?X-Amz-Algorithm=AWS4-HMAC-SHA256.*X-Amz-Expires=300}, response.location
    assert_equal "backup.download", AuditLog.last.action_name
  end
end
