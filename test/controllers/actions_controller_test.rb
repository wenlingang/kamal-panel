require "test_helper"

class ActionsControllerTest < ActionDispatch::IntegrationTest
  # Note: the variable can't be named @app -- ActionDispatch::IntegrationTest itself reserves the
  # @app instance variable for the Rack app under test (ActionDispatch::Integration::Runner#app).
  # Assigning @app in setup overrides it, so integration_session treats this ManagedApp as the Rack
  # app and every route helper (e.g. session_path) stops working.
  setup do
    @managed_app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  def sign_in(role)
    User.create!(email_address: "#{role}@example.com", password: "secret123456", role: role)
    post session_path, params: { email_address: "#{role}@example.com", password: "secret123456" }
  end

  test "rejects an unknown action name without writing an audit entry" do
    sign_in("admin")
    assert_no_difference("AuditLog.count") do
      post managed_app_actions_path(@managed_app), params: { name: "exec" }
    end
  end

  test "admin triggering restart records a pending audit entry" do
    sign_in("admin")
    assert_difference("AuditLog.count", 1) do
      post managed_app_actions_path(@managed_app), params: { name: "restart" }
    end
    assert_equal "pending", AuditLog.last.result
  end

  test "developer cannot trigger actions on someone else's app" do
    sign_in_as users(:three)

    post managed_app_actions_path(@managed_app), params: { name: "start" }

    assert_redirected_to managed_app_path(@managed_app, tab: "actions")
    assert_equal "没有权限执行该操作", flash[:alert]
    assert_equal 0, AuditLog.where(managed_app: @managed_app).count,
      "A rejected action must never leave an audit record; it would show operations that never happened in the audit log"
  end

  # The title says "any", so actually run through every registered write action -- testing only
  # start means that if someone later adds a bypass for one action, this test still won't go red.
  # Note that confirm_by_name? is true for stop / rollback: they aren't even given a confirmation
  # name, yet must still be rejected as "no permission" -- the permission check comes before the
  # confirmation check, and this order is itself pinned by this case (the reverse would tell someone
  # with no right to act that "you mistyped the name").
  test "ops cannot trigger any action that mutates production state" do
    sign_in_as users(:one)

    %w[ start restart stop rollback force_unlock maintenance live accessory_restart accessory_reboot
        proxy_restart prune ].each do |name|
      post managed_app_actions_path(@managed_app), params: { name: }

      assert_redirected_to managed_app_path(@managed_app, tab: "actions")
      assert_equal "没有权限执行该操作", flash[:alert], "#{name} should be rejected as unauthorized"
      assert_equal 0, AuditLog.where(managed_app: @managed_app).count,
        "rejected #{name} must not leave any audit record"
    end
  end

  # The execution page renders the action's full output. ops can run logs site-wide, so as soon as
  # it has run once, this URL exists; show previously had no authorization check, so any logged-in
  # user could read all 200 lines of service logs. Design 11 §3.1 makes only the app name, version
  # and machine address visible to developers across teams; log contents are not part of that
  # trade-off.
  def logs_entry(app = @managed_app, output: "绝密日志一行")
    AuditLog.create!(user: users(:one), managed_app: app, action_name: "logs",
                     hosts: [ "10.0.0.1" ], result: "success", output_digest: output)
  end

  def accessory_app
    ManagedApp.create!(name: "shop", config_yaml: file_fixture("accessory_deploy.yml").read,
                       destination: "production")
  end
end
