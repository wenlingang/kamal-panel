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

  test "ops 不能发起动作" do
    sign_in("ops")
    assert_no_difference("AuditLog.count") do
      post managed_app_actions_path(@managed_app), params: { name: "restart" }
    end
  end

  test "未知动作名被拒绝且不落审计" do
    sign_in("admin")
    assert_no_difference("AuditLog.count") do
      post managed_app_actions_path(@managed_app), params: { name: "exec" }
    end
  end

  test "需要手输应用名的动作，名字不对则不执行" do
    sign_in("admin")
    assert_no_difference("AuditLog.count") do
      post managed_app_actions_path(@managed_app), params: { name: "stop", confirm_name: "wrong" }
    end
  end

  test "admin 发起 restart 会落一条 pending 审计" do
    sign_in("admin")
    assert_difference("AuditLog.count", 1) do
      post managed_app_actions_path(@managed_app), params: { name: "restart" }
    end
    assert_equal "pending", AuditLog.last.result
  end

  test "developer 能对名下应用发起动作" do
    AppMembership.create!(user: users(:three), managed_app: @managed_app)
    sign_in_as users(:three)

    post managed_app_actions_path(@managed_app), params: { name: "start" }

    assert_equal 1, AuditLog.where(managed_app: @managed_app).count
  end

  test "developer 不能对别人的应用发起动作" do
    sign_in_as users(:three)

    post managed_app_actions_path(@managed_app), params: { name: "start" }

    assert_redirected_to managed_app_path(@managed_app)
    assert_equal "没有权限执行该操作", flash[:alert]
    assert_equal 0, AuditLog.where(managed_app: @managed_app).count,
      "被拒的动作绝不能留下审计记录——那会让审计里出现从未发生过的操作"
  end

  # The title says "any", so actually run through every registered write action -- testing only
  # start means that if someone later adds a bypass for one action, this test still won't go red.
  # Note that confirm_by_name? is true for stop / rollback: they aren't even given a confirmation
  # name, yet must still be rejected as "no permission" -- the permission check comes before the
  # confirmation check, and this order is itself pinned by this case (the reverse would tell someone
  # with no right to act that "you mistyped the name").
  test "ops 不能发起任何会改变线上状态的动作" do
    sign_in_as users(:one)

    %w[ start restart stop rollback force_unlock ].each do |name|
      post managed_app_actions_path(@managed_app), params: { name: }

      assert_redirected_to managed_app_path(@managed_app)
      assert_equal "没有权限执行该操作", flash[:alert], "#{name} 应该以「没有权限」被拒"
      assert_equal 0, AuditLog.where(managed_app: @managed_app).count,
        "被拒的 #{name} 不该留下任何审计记录"
    end
  end

  test "ops 能看日志——这是它唯一能发起的动作" do
    sign_in_as users(:one)

    post managed_app_actions_path(@managed_app), params: { name: "logs" }

    log = AuditLog.where(managed_app: @managed_app).sole
    assert_equal "logs", log.action_name
    assert_redirected_to managed_app_action_path(@managed_app, log)
  end

  test "developer 不能看别人应用的日志" do
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

  test "非名下的 developer 打不开别人应用的 logs 执行页" do
    log = logs_entry
    sign_in_as users(:three)

    get managed_app_action_path(@managed_app, log)

    assert_redirected_to managed_app_path(@managed_app)
    assert_equal "没有权限执行该操作", flash[:alert]
    refute_includes response.body.to_s, "绝密日志一行"
  end

  test "ops 能打开 logs 执行页" do
    log = logs_entry
    sign_in_as users(:one)

    get managed_app_action_path(@managed_app, log)

    assert_response :success
    assert_includes response.body, "绝密日志一行"
  end

  test "admin 能打开 logs 执行页" do
    log = logs_entry
    sign_in_as users(:two)

    get managed_app_action_path(@managed_app, log)

    assert_response :success
    assert_includes response.body, "绝密日志一行"
  end

  test "名下的 developer 能打开自己应用的 logs 执行页" do
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
  test "别的应用的审计 id 不能挂在这个应用下渲染" do
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
  test "权限审计行的执行页被拒绝，而不是 500" do
    membership_log = AuditLog.record_access!(user: users(:two), action_name: "app.add_member",
                                             target_user: users(:three),
                                             managed_app_id: @managed_app.id)
    sign_in_as users(:two)

    get managed_app_action_path(@managed_app, membership_log)

    assert_redirected_to managed_app_path(@managed_app)
    assert_equal "没有权限执行该操作", flash[:alert]
  end
end
