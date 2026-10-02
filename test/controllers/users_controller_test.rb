require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  # Careful not to call it @app: ActionDispatch::IntegrationTest uses @app to remember the app under
  # test (the Rack app); overriding it makes every *_path helper in the whole case disappear.
  setup do
    @managed_app = ManagedApp.create!(name: "blog",
                              config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  # If we only probed index, this title would assert coverage that doesn't exist -- and that is
  # exactly why gaps like this can live on forever. So every state-changing action must actually be
  # hit, and we assert the state is unchanged, not just the redirect: controllers exist that
  # redirect correctly and still performed the write.
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

      # The person used to test "activate" can't be the actor themselves: deactivate! destroys their
      # sessions as a side effect, and the following request becomes "not logged in", so what's
      # tested is no longer permissions.
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

  # Only integration tests render these two pages (system tests don't cover the users pages), so if
  # the ERB is wrong, they're what raises the alarm.
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

  # admin shouldn't know other people's passwords. Creating a user takes only email and role; the
  # password is set by the user through the existing password-recovery flow.
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

  # Both the "send email" and "admin sets the password directly" paths must work. The default is
  # still sending email -- admin not knowing other people's passwords remains the better default;
  # setting the password directly is a back door left for cases like "the recipient can't receive
  # email / intranet with no outbound mail".
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

  # When the form is sent back, remember to carry the "set password directly" choice along,
  # otherwise after the admin mistypes a password once the form quietly snaps back to "send email",
  # and submitting again yields an email they never meant to send.
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

  # "The admin knows this person's password" is a fact worth leaving an audit trace of, and the two
  # paths must be distinguishable in the log.
  test "两种设密码方式在审计日志里可区分" do
    sign_in_as users(:two)

    post users_path, params: { password_setup: "manual",
                               user: { email_address: "manual@example.com", role: "ops",
                                       password: "secret123456",
                                       password_confirmation: "secret123456" } }
    post users_path, params: { user: { email_address: "mailed@example.com", role: "ops" } }

    # Store the key, not the Chinese text: audit rows are append-only, and writing Chinese into them
    # welds the language permanently into the data, so when we later display in another language
    # these historical rows can't be translated at all.
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

  # If role didn't change, no user.update_role should be left behind -- an audit entry for a role
  # change that never happened is worse than no record: whoever investigates will follow it to look
  # for something that never occurred.
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

  # The hidden field behind the "select none" checkbox in the form brings in an empty string. Its
  # to_i is 0, and no app with id 0 exists -- if it isn't filtered out, AppMembership.create! raises
  # a foreign key error.
  test "表单里的空隐藏字段不会被当成一个应用" do
    sign_in_as users(:two)

    patch user_path(users(:three)), params: { user: { role: "developer" },
                                              managed_app_ids: [ "", @managed_app.id.to_s ] }

    assert_redirected_to users_path
    assert_equal [ @managed_app.id ], users(:three).reload.managed_app_ids
    assert_equal 1, AuditLog.where(action_name: "app.add_member").count
  end

  # The edit page renders only role and membership, but params can be forged. Allowing email changes
  # means allowing changes to someone else's login name, and after that the public password-recovery
  # flow takes over that account -- and this path writes not even one audit line when role doesn't
  # change at the same time.
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

  # If the last admin is deactivated or demoted, nobody in the panel can manage people, manage
  # credentials or onboard apps anymore
  # -- and recovering requires opening a rails console on the server. That's a one-way dead end, and it must be stopped
  # before it happens.
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

  # Email uniqueness used to be backstopped only by the database index: a duplicate email would
  # crash straight into RecordNotUnique (500), so the render :new branch in create and the error
  # list on the new page were never reachable.
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

  # Design 11 §2.2: admin and ops never go in the membership table. If the row is kept on demotion,
  # when they are later promoted back to developer, the apps under their name come back to life as
  # they were -- nobody made that decision.
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
