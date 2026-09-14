require "test_helper"

class ActionsControllerTest < ActionDispatch::IntegrationTest
  # 注意：变量名不能叫 @app —— ActionDispatch::IntegrationTest 自身把
  # 实例变量 @app 保留给被测的 Rack 应用（ActionDispatch::Integration::Runner#app）。
  # setup 里赋值 @app 会覆盖它，导致 integration_session 把这个 ManagedApp
  # 当成 Rack app 来用，所有路由 helper（如 session_path）随即失效。
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

  # 标题说的是「任何」，那就真的把已注册的写动作都过一遍——只测 start 的话，
  # 哪天有人给某个动作单独开一条旁路，这条测试也不会变红。
  # 注意 stop / rollback 的 confirm_by_name? 是 true：它们连确认名都没给，
  # 却仍然应该以「没有权限」被拒——权限判断排在确认判断之前，这个顺序本身
  # 也被这条用例钉住了（反过来会把「你名字打错了」告诉一个根本无权操作的人）。
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

  # 执行页会把动作的完整输出渲染出来。ops 全站都能跑 logs，所以只要它跑过一次，
  # 这条 URL 就存在；show 上此前没有任何授权判断，于是任何登录用户都能把那 200 行
  # 服务日志读完。设计 11 第 3.1 节让 developer 跨团队可见的只有应用名、版本号与
  # 机器地址，日志内容不在那笔取舍里。
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

  # 审计记录不限定在应用下的话，/apps/<甲>/actions/<乙的 id> 会把乙的执行输出
  # 挂在甲的面包屑下渲染出来——授权判断问的是甲，读到的却是乙。
  test "别的应用的审计 id 不能挂在这个应用下渲染" do
    other = ManagedApp.create!(name: "shop",
                       config_yaml: file_fixture("simple_deploy.yml").read,
                       destination: "production")
    foreign = logs_entry(other, output: "别人的日志")
    sign_in_as users(:two)

    # test 环境 show_exceptions = :rescuable，异常会被兜成一张 404 调试页；这里
    # 临时关掉它，好让断言直接落在"查不到这条记录"上，而不是一个状态码。
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

  # 权限变更的审计行（app.add_member / app.remove_member）也带着 managed_app_id，
  # 作用域那一关拦不住它们，而 Actions::Base.find 不认这种 action_name。此前这会
  # 变成一条手输 URL 就能打出来的 500；它们属于审计列表，不属于执行页。
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
