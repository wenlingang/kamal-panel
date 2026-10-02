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

  test "ops cannot trigger actions" do
    sign_in("ops")
    assert_no_difference("AuditLog.count") do
      post managed_app_actions_path(@managed_app), params: { name: "restart" }
    end
  end

  test "rejects an unknown action name without writing an audit entry" do
    sign_in("admin")
    assert_no_difference("AuditLog.count") do
      post managed_app_actions_path(@managed_app), params: { name: "exec" }
    end
  end

  test "does not execute an action requiring a typed app name when the name is wrong" do
    sign_in("admin")
    assert_no_difference("AuditLog.count") do
      post managed_app_actions_path(@managed_app), params: { name: "stop", confirm_name: "wrong" }
    end
  end

  test "admin triggering restart records a pending audit entry" do
    sign_in("admin")
    assert_difference("AuditLog.count", 1) do
      post managed_app_actions_path(@managed_app), params: { name: "restart" }
    end
    assert_equal "pending", AuditLog.last.result
  end

  test "developer can trigger actions on an app they own" do
    AppMembership.create!(user: users(:three), managed_app: @managed_app)
    sign_in_as users(:three)

    post managed_app_actions_path(@managed_app), params: { name: "start" }

    assert_equal 1, AuditLog.where(managed_app: @managed_app).count
  end

  test "developer cannot trigger actions on someone else's app" do
    sign_in_as users(:three)

    post managed_app_actions_path(@managed_app), params: { name: "start" }

    assert_redirected_to managed_app_path(@managed_app)
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

    %w[ start restart stop rollback force_unlock ].each do |name|
      post managed_app_actions_path(@managed_app), params: { name: }

      assert_redirected_to managed_app_path(@managed_app)
      assert_equal "没有权限执行该操作", flash[:alert], "#{name} should be rejected as unauthorized"
      assert_equal 0, AuditLog.where(managed_app: @managed_app).count,
        "rejected #{name} must not leave any audit record"
    end
  end

  test "ops can view logs, the only action it can trigger" do
    sign_in_as users(:one)

    post managed_app_actions_path(@managed_app), params: { name: "logs" }

    log = AuditLog.where(managed_app: @managed_app).sole
    assert_equal "logs", log.action_name
    assert_redirected_to managed_app_action_path(@managed_app, log)
  end

  test "developer cannot view logs of someone else's app" do
    sign_in_as users(:three)

    post managed_app_actions_path(@managed_app), params: { name: "logs" }

    assert_equal "没有权限执行该操作", flash[:alert]
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

  test "developer cannot open the logs execution page of an app they do not own" do
    log = logs_entry
    sign_in_as users(:three)

    get managed_app_action_path(@managed_app, log)

    assert_redirected_to managed_app_path(@managed_app)
    assert_equal "没有权限执行该操作", flash[:alert]
    refute_includes response.body.to_s, "绝密日志一行"
  end

  test "ops can open the logs execution page" do
    log = logs_entry
    sign_in_as users(:one)

    get managed_app_action_path(@managed_app, log)

    assert_response :success
    assert_includes response.body, "绝密日志一行"
  end

  test "admin can open the logs execution page" do
    log = logs_entry
    sign_in_as users(:two)

    get managed_app_action_path(@managed_app, log)

    assert_response :success
    assert_includes response.body, "绝密日志一行"
  end

  test "developer can open the logs execution page of their own app" do
    log = logs_entry
    AppMembership.create!(user: users(:three), managed_app: @managed_app)
    sign_in_as users(:three)

    get managed_app_action_path(@managed_app, log)

    assert_response :success
    assert_includes response.body, "绝密日志一行"
  end

  # If audit records aren't scoped to the app, /apps/<A>/actions/<B's id> renders B's execution
  # output under A's breadcrumb -- the authorization check asks about A, but what is read belongs to
  # B.
  test "does not render another app's audit id under this app" do
    other = ManagedApp.create!(name: "shop",
                       config_yaml: file_fixture("simple_deploy.yml").read,
                       destination: "production")
    foreign = logs_entry(other, output: "别人的日志")
    sign_in_as users(:two)

    # The test env has show_exceptions = :rescuable, so the exception would be wrapped into a 404
    # debug page; here we turn that off temporarily so the assertion lands directly on "record not
    # found" instead of a status code.
    env_config = Rails.application.env_config
    original = env_config["action_dispatch.show_exceptions"]
    env_config["action_dispatch.show_exceptions"] = :none

    begin
      assert_raises(ActiveRecord::RecordNotFound) do
        get managed_app_action_path(@managed_app, foreign)
      end
    ensure
      env_config["action_dispatch.show_exceptions"] = original
    end
  end

  # Permission-change audit rows (app.add_member / app.remove_member) also carry managed_app_id, the
  # scoping step can't stop them, and Actions::Base.find doesn't recognize such action_names. This
  # used to become a 500 reachable just by typing a URL; they belong to the audit list, not the
  # execution page.
  test "denies the execution page for a permission audit row instead of returning 500" do
    membership_log = AuditLog.record_access!(user: users(:two), action_name: "app.add_member",
                                             target_user: users(:three),
                                             managed_app_id: @managed_app.id)
    sign_in_as users(:two)

    get managed_app_action_path(@managed_app, membership_log)

    assert_redirected_to managed_app_path(@managed_app)
    assert_equal "没有权限执行该操作", flash[:alert]
  end
end
