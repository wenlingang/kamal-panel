require "test_helper"

class AppMembershipTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog",
                              config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    @user = users(:three) # developer
  end

  test "成员关系双向可读" do
    AppMembership.create!(user: @user, managed_app: @app)

    assert_includes @app.members, @user
    assert_includes @user.managed_apps, @app
    assert_includes @app.member_ids, @user.id
  end

  test "同一个人在同一个应用上不能重复成为成员" do
    AppMembership.create!(user: @user, managed_app: @app)

    assert_raises(ActiveRecord::RecordNotUnique) do
      AppMembership.insert!({ user_id: @user.id, managed_app_id: @app.id, created_at: Time.current })
    end
  end

  test "应用被删时成员行跟着消失" do
    AppMembership.create!(user: @user, managed_app: @app)

    @app.destroy

    assert_equal 0, AppMembership.where(managed_app_id: @app.id).count
  end

  test "用户被停用不影响成员行——停用不是删除" do
    AppMembership.create!(user: @user, managed_app: @app)

    @user.deactivate!

    assert_includes @app.reload.members, @user
  end
end
