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
  test "denies non-admins every state-changing action" do
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

  # If the last admin is deactivated or demoted, nobody in the panel can manage people, manage
  # credentials or onboard apps anymore
  # -- and recovering requires opening a rails console on the server. That's a one-way dead end, and it must be stopped
  # before it happens.
  test "cannot deactivate the last admin" do
    sign_in_as users(:two)

    post deactivate_user_path(users(:two))

    # Only admins deactivate people, so the last admin can only be targeted by themselves: the
    # self-deactivation rule fires first. The last-admin check stays as a second line of defence.
    refute_predicate users(:two).reload, :deactivated?
    assert_equal I18n.t("flash.user.self_deactivate"), flash[:alert]
  end

  test "cannot downgrade the last admin" do
    sign_in_as users(:two)

    patch user_path(users(:two)), params: { user: { role: "ops" } }

    assert_equal "admin", users(:two).reload.role
    assert_equal "不能降级最后一个 admin", flash[:alert]
  end
end
