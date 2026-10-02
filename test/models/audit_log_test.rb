require "test_helper"

class AuditLogTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email_address: "op@example.com", password: "secret123456", role: "admin")
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  # Action names are translated on the page, and when no translation is found it falls
  # back to the raw action_name (a safety net for "renamed in code, audit rows still carry
  # the old name"). That fallback also masks "added a new action but forgot the
  # translation" -- so here we check coverage head-on, rather than hoping someone spots
  # an English key popping up on the page.
  test "every action name written to the audit log has Chinese and English translations" do
    AuditLog.all_action_names.each do |name|
      %i[zh-CN en].each do |locale|
        assert I18n.exists?("audit.actions.#{name}", locale),
               "action #{name} is missing its #{locale} translation"
      end
    end
  end

  test "the action name list covers both deploy actions and permission actions" do
    assert_includes AuditLog.all_action_names, "rollback"
    assert_includes AuditLog.all_action_names, "user.create"
  end

  test "detail_args is stored as JSON and reads back with the original structure" do
    log = AuditLog.record_access!(user: @user, action_name: "app.update",
                                  managed_app: @app,
                                  detail_key: "app.update_fields",
                                  detail_args: { "fields" => %w[name kamal_secrets] })

    assert_equal %w[name kamal_secrets], log.reload.detail_args["fields"]
  end

  test "start! first records a pending entry" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "rollback",
                          target_version: "aaaaaaa", hosts: [ "10.0.0.1" ])

    assert_equal "pending", log.result
    assert_nil log.finished_at
  end

  test "finish! updates the result and duration" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "restart",
                          target_version: nil, hosts: [ "10.0.0.1" ])
    log.finish!(result: "success", command: "kamal app restart", output_digest: "ok", duration_ms: 1234)

    assert_equal "success", log.reload.result
    assert_equal 1234, log.duration_ms
    assert_not_nil log.finished_at
  end

  test "audit logs cannot be destroyed" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "stop",
                          target_version: nil, hosts: [])

    assert_raises(ActiveRecord::ReadOnlyRecord) { log.destroy }
  end

  test "audit logs cannot be bypassed with delete either" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "stop",
                          target_version: nil, hosts: [])

    assert_raises(ActiveRecord::ReadOnlyRecord) { log.delete }
  end

  test "pending records left behind by a mid-run crash can still be queried" do
    AuditLog.start!(user: @user, managed_app: @app, action_name: "rollback",
                    target_version: "aaaaaaa", hosts: [ "10.0.0.1" ])

    assert_equal 1, AuditLog.where(result: "pending").count
  end

  test "destroying a ManagedApp does not delete its audit logs" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "stop",
                          target_version: nil, hosts: [])

    assert_raises(ActiveRecord::InvalidForeignKey) { @app.destroy! }
    assert AuditLog.exists?(log.id)
  end

  test "destroying a User does not delete their audit logs" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "stop",
                          target_version: nil, hosts: [])

    assert_raises(ActiveRecord::InvalidForeignKey) { @user.destroy! }
    assert AuditLog.exists?(log.id)
  end

  test "AuditLog.delete_all cannot bypass the guard" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "stop",
                          target_version: nil, hosts: [])

    assert_raises(ActiveRecord::ReadOnlyRecord) { AuditLog.delete_all }
    assert AuditLog.exists?(log.id)
  end

  test "relation.delete_all cannot bypass the guard" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "stop",
                          target_version: nil, hosts: [])

    assert_raises(ActiveRecord::ReadOnlyRecord) { AuditLog.where(id: log.id).delete_all }
    assert AuditLog.exists?(log.id)
  end

  test "AuditLog.delete(id) cannot bypass the guard" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "stop",
                          target_version: nil, hosts: [])

    assert_raises(ActiveRecord::ReadOnlyRecord) { AuditLog.delete(log.id) }
    assert AuditLog.exists?(log.id)
  end

  test "AuditLog.delete_by cannot bypass the guard" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "stop",
                          target_version: nil, hosts: [])

    assert_raises(ActiveRecord::ReadOnlyRecord) { AuditLog.delete_by(id: log.id) }
    assert AuditLog.exists?(log.id)
  end

  test "finish! rejects an invalid result without leaving a half-updated row" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "restart",
                          target_version: nil, hosts: [])

    assert_raises(ArgumentError) do
      log.finish!(result: "bogus", command: "kamal app restart", output_digest: "??", duration_ms: 1)
    end

    log.reload
    assert_equal "pending", log.result
    assert_nil log.finished_at
    assert_nil log.duration_ms
  end

  test "a permission change is recorded as an audit entry that belongs to no app" do
    log = AuditLog.record_access!(user: users(:two), action_name: "user.update_role",
                                  target_user: users(:one))

    assert_nil log.managed_app
    assert_equal users(:one), log.target_user
    assert_equal "success", log.result
    assert_not_nil log.finished_at, "a permission change completes on the spot and should not stay pending"
  end

  test "a member change carries both the app and the affected person" do
    log = AuditLog.record_access!(user: users(:two), action_name: "app.add_member",
                                  target_user: users(:three), managed_app: @app)

    assert_equal @app, log.managed_app
    assert_equal users(:three), log.target_user
  end

  test "permission change records cannot be deleted either" do
    log = AuditLog.record_access!(user: users(:two), action_name: "user.deactivate",
                                  target_user: users(:one))

    assert_raises(ActiveRecord::ReadOnlyRecord) { log.destroy }
  end
end
