require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  # 注意别把它叫 @app：ActionDispatch::IntegrationTest 用 @app 记住被测的
  # Rack 应用，覆盖掉它，整个用例里所有的 *_path 助手都会消失。
  setup do
    @managed_app = ManagedApp.create!(name: "blog",
                              config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  # 只探 index 的话，这个标题断言的是一份并不存在的覆盖——而那正是这种缺口
  # 能一直活下去的原因。所以每一个会改变状态的动作都要真的打一遍，并且断言
  # 状态没变，不能只看重定向：重定向对了而写入照样发生过的控制器是存在的。
  test "非 admin 一个会改状态的动作都进不去" do
    [ users(:one), users(:three) ].each do |actor|
      victim = users(:two)
      before_count = User.count

      sign_in_as actor

      get users_path
      assert_redirected_to root_path
      assert_equal "没有权限执行该操作", flash[:alert]

      get new_user_path
      assert_redirected_to root_path

      get edit_user_path(victim)
      assert_redirected_to root_path

      post users_path, params: { user: { email_address: "sneak@example.com", role: "admin" } }
      assert_redirected_to root_path
      assert_equal before_count, User.count
      assert_nil User.find_by(email_address: "sneak@example.com")

      patch user_path(users(:one)), params: { user: { role: "admin" } }
      assert_redirected_to root_path
      assert_equal "ops", users(:one).reload.role

      post deactivate_user_path(users(:one))
      assert_redirected_to root_path
      refute_predicate users(:one).reload, :deactivated?

      # 拿来试"启用"的人不能是 actor 自己：deactivate! 会顺手销毁他的会话，
      # 后面的请求就变成"未登录"，测的就不再是权限了。
      other = actor == users(:one) ? users(:three) : users(:one)
      other.deactivate!
      post reactivate_user_path(other)
      assert_redirected_to root_path
      assert_predicate other.reload, :deactivated?
      other.reactivate!

      assert_empty AuditLog.where(user: actor)
      sign_out
    end
  end

  test "未登录进不去" do
    get users_path
    assert_redirected_to new_session_path
  end

  test "admin 能看到人员列表" do
    sign_in_as users(:two)

    get users_path

    assert_response :success
    assert_select "td", text: "one@example.com"
  end

  # 这两页只有集成测试会渲染到（系统测试不覆盖人员页），ERB 写错了就靠它们报警。
  test "新建与编辑两页都能渲染" do
    sign_in_as users(:two)

    get new_user_path
    assert_response :success
    assert_select "select#user_role option", text: "开发者"

    get edit_user_path(users(:three))
    assert_response :success
    assert_select "input[type=checkbox][name='managed_app_ids[]'][value=?]", @managed_app.id.to_s
    assert_select "input[type=hidden][name='managed_app_ids[]']"
  end

  # admin 不该知道别人的密码。新建用户只填邮箱与角色，密码由对方通过
  # 现有的找回密码流程自己设置。
  test "新建用户不设密码，发一封设置密码的邮件" do
    sign_in_as users(:two)

    assert_difference -> { User.count }, 1 do
      assert_enqueued_emails 1 do
        post users_path, params: { user: { email_address: "new@example.com", role: "developer" } }
      end
    end

    created = User.find_by(email_address: "new@example.com")
    assert_equal "developer", created.role
  end

  # 「发邮件」和「管理员直接设密码」两条路都要能用。默认仍是发邮件——
  # 管理员不知道别人的密码依然是更好的默认值，直接设密码是给
  # 「对方收不到邮件 / 内网无外发邮件」这类情况留的后门。
  test "选择直接设置密码：不发邮件，且对方能用这个密码登录" do
    sign_in_as users(:two)

    assert_difference -> { User.count }, 1 do
      assert_no_enqueued_emails do
        post users_path, params: { password_setup: "manual",
                                   user: { email_address: "new@example.com", role: "ops",
                                           password: "secret123456",
                                           password_confirmation: "secret123456" } }
      end
    end

    sign_out
    post session_path, params: { email_address: "new@example.com", password: "secret123456" }
    assert_redirected_to root_path
  end

  test "直接设置密码时两次输入不一致：不建用户，退回表单" do
    sign_in_as users(:two)

    assert_no_difference -> { User.count } do
      post users_path, params: { password_setup: "manual",
                                 user: { email_address: "new@example.com", role: "ops",
                                         password: "secret123456",
                                         password_confirmation: "secret999999" } }
    end

    assert_response :unprocessable_entity
  end

  # 退回表单时要记得把「直接设密码」这个选择带回去，否则管理员填错一次密码，
  # 表单就悄悄弹回「发邮件」，他再点一次提交就得到一封自己没想发的邮件。
  test "直接设置密码失败退回时，表单仍停在「直接设置密码」上" do
    sign_in_as users(:two)

    post users_path, params: { password_setup: "manual",
                               user: { email_address: "new@example.com", role: "ops",
                                       password: "secret123456",
                                       password_confirmation: "secret999999" } }

    assert_select "input[type=radio][name=password_setup][value=manual][checked=checked]"
  end

  test "直接设置密码：密码太短会被拒" do
    sign_in_as users(:two)

    assert_no_difference -> { User.count } do
      post users_path, params: { password_setup: "manual",
                                 user: { email_address: "new@example.com", role: "ops",
                                         password: "short7c", password_confirmation: "short7c" } }
    end

    assert_response :unprocessable_entity
  end

  # 「管理员知道这个人的密码」是审计上值得留痕的事实，两条路要能在日志里分开。
  test "两种设密码方式在审计日志里可区分" do
    sign_in_as users(:two)

    post users_path, params: { password_setup: "manual",
                               user: { email_address: "manual@example.com", role: "ops",
                                       password: "secret123456",
                                       password_confirmation: "secret123456" } }
    post users_path, params: { user: { email_address: "mailed@example.com", role: "ops" } }

    # 存的是 key 不是中文：审计行只增不删，往里写中文等于把语言永久焊死在
    # 数据里，将来换一种语言显示时这些历史行没有任何办法翻译。
    by_target = AuditLog.where(action_name: "user.create").index_by { |l| l.target_user.email_address }
    assert_equal "user.password_by_admin", by_target["manual@example.com"].detail_key
    assert_equal "user.password_by_mail", by_target["mailed@example.com"].detail_key
    assert_nil by_target["manual@example.com"].detail
  end

  test "新建用户写审计" do
    sign_in_as users(:two)

    post users_path, params: { user: { email_address: "new@example.com", role: "ops" } }

    log = AuditLog.where(action_name: "user.create").sole
    assert_equal users(:two), log.user
    assert_equal "new@example.com", log.target_user.email_address
  end

  test "新建成员时可以带昵称" do
    sign_in_as users(:two)

    post users_path, params: { user: { email_address: "new@example.com", role: "ops",
                                       nickname: "老王" } }

    assert_equal "老王", User.find_by(email_address: "new@example.com").nickname
  end

  test "编辑页可以改昵称" do
    sign_in_as users(:two)

    patch user_path(users(:one)), params: { user: { role: "ops", nickname: "小李" } }

    assert_equal "小李", users(:one).reload.nickname
  end

  # role 没变就不该留下一条 user.update_role——审计里出现一次并不存在的角色
  # 变更，比没有记录更糟：查的人会顺着它去找一个从没发生过的事。
  test "只改昵称不写改角色的审计" do
    sign_in_as users(:two)

    patch user_path(users(:one)), params: { user: { role: users(:one).role, nickname: "小李" } }

    assert_equal "小李", users(:one).reload.nickname
    assert_empty AuditLog.where(action_name: "user.update_role")
  end

  test "人员列表显示昵称，邮箱仍然保留" do
    users(:one).update!(nickname: "老王")
    sign_in_as users(:two)

    get users_path

    assert_select "td", text: "老王"
    assert_select "td", text: "one@example.com"
  end

  test "改角色写审计" do
    sign_in_as users(:two)

    patch user_path(users(:one)), params: { user: { role: "developer" } }

    assert_equal "developer", users(:one).reload.role
    assert_equal 1, AuditLog.where(action_name: "user.update_role").count
  end

  test "指派成员：勾选应用即成为该应用的成员，并写审计" do
    sign_in_as users(:two)

    patch user_path(users(:three)), params: { user: { role: "developer" },
                                              managed_app_ids: [ @managed_app.id ] }

    assert_includes @managed_app.reload.members, users(:three)
    log = AuditLog.where(action_name: "app.add_member").sole
    assert_equal @managed_app, log.managed_app
    assert_equal users(:three), log.target_user
  end

  test "取消勾选即解除成员关系，并写审计" do
    AppMembership.create!(user: users(:three), managed_app: @managed_app)
    sign_in_as users(:two)

    patch user_path(users(:three)), params: { user: { role: "developer" }, managed_app_ids: [] }

    refute_includes @managed_app.reload.members, users(:three)
    log = AuditLog.where(action_name: "app.remove_member").sole
    assert_equal @managed_app, log.managed_app
    assert_equal users(:three), log.target_user
  end

  # 表单里那个"全不勾"用的隐藏字段会带来一个空字符串。它 to_i 是 0，
  # 而不存在 id 为 0 的应用——不滤掉就会在 AppMembership.create! 上抛外键错误。
  test "表单里的空隐藏字段不会被当成一个应用" do
    sign_in_as users(:two)

    patch user_path(users(:three)), params: { user: { role: "developer" },
                                              managed_app_ids: [ "", @managed_app.id.to_s ] }

    assert_redirected_to users_path
    assert_equal [ @managed_app.id ], users(:three).reload.managed_app_ids
    assert_equal 1, AuditLog.where(action_name: "app.add_member").count
  end

  # 编辑页只渲染角色与成员，但参数是可以伪造的。允许改邮箱等于允许改别人的
  # 登录名，改完再走公开的找回密码流程就接管了那个账号——而这条路径在角色
  # 没同时变化时连一行审计都不写。
  test "update 改不了别人的登录邮箱" do
    sign_in_as users(:two)

    patch user_path(users(:one)), params: { user: { email_address: "hijack@example.com",
                                                    role: "developer" } }

    assert_equal "one@example.com", users(:one).reload.email_address
    assert_nil User.find_by(email_address: "hijack@example.com")
  end

  test "停用与启用都写审计" do
    sign_in_as users(:two)

    post deactivate_user_path(users(:one))
    assert_predicate users(:one).reload, :deactivated?

    post reactivate_user_path(users(:one))
    refute_predicate users(:one).reload, :deactivated?

    assert_equal 1, AuditLog.where(action_name: "user.deactivate").count
    assert_equal 1, AuditLog.where(action_name: "user.reactivate").count
  end

  # 把最后一个 admin 停用或降级，面板就再也没有人能管人、管凭据、接入应用了
  # ——而恢复它需要去服务器上开 rails console。这是一个单向的死局，必须在
  # 发生之前拦住。
  test "不能停用最后一个 admin" do
    sign_in_as users(:two)

    post deactivate_user_path(users(:two))

    refute_predicate users(:two).reload, :deactivated?
    assert_equal "不能停用最后一个 admin", flash[:alert]
  end

  test "不能把最后一个 admin 降级" do
    sign_in_as users(:two)

    patch user_path(users(:two)), params: { user: { role: "ops" } }

    assert_equal "admin", users(:two).reload.role
    assert_equal "不能降级最后一个 admin", flash[:alert]
  end

  # 邮箱唯一性此前只有数据库索引兜着：重复邮箱会直接撞成 RecordNotUnique（500），
  # 于是 create 里那条 render :new 分支和新建页上的错误列表根本没人走得到。
  test "空邮箱被拦下，不建用户也不写审计" do
    sign_in_as users(:two)

    assert_no_difference [ -> { User.count }, -> { AuditLog.count } ] do
      post users_path, params: { user: { email_address: "", role: "ops" } }
    end

    assert_response :unprocessable_entity
    assert_select "ul.errors li"
  end

  test "重复邮箱被拦下，不建用户也不写审计，更不是 500" do
    sign_in_as users(:two)

    assert_no_difference [ -> { User.count }, -> { AuditLog.count } ] do
      post users_path, params: { user: { email_address: "one@example.com", role: "ops" } }
    end

    assert_response :unprocessable_entity
    assert_select "ul.errors li"
  end

  # 设计 11 第 2.2 节：admin 与 ops 永远不进成员表。降级时若把行留着，日后再升回
  # developer，他名下的那批应用会原样复活——没有人做过这个决定。
  test "developer 降成 ops 会清空成员行，并为每个应用写一条 remove_member" do
    other = ManagedApp.create!(name: "shop",
                       config_yaml: file_fixture("simple_deploy.yml").read,
                       destination: "production")
    AppMembership.create!(user: users(:three), managed_app: @managed_app)
    AppMembership.create!(user: users(:three), managed_app: other)
    sign_in_as users(:two)

    patch user_path(users(:three)), params: { user: { role: "ops" },
                                              managed_app_ids: [ @managed_app.id ] }

    assert_equal "ops", users(:three).reload.role
    assert_empty users(:three).managed_app_ids
    assert_equal 2, AuditLog.where(action_name: "app.remove_member").count
    assert_equal [ users(:three) ], AuditLog.where(action_name: "app.remove_member").map(&:target_user).uniq
  end

  test "给 ops 勾应用不会建出任何成员行" do
    sign_in_as users(:two)

    patch user_path(users(:one)), params: { user: { role: "ops" },
                                            managed_app_ids: [ @managed_app.id ] }

    assert_empty users(:one).reload.managed_app_ids
    assert_empty AuditLog.where(action_name: "app.add_member")
  end
end
