require "test_helper"

class AppMembershipTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog",
                              config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    @user = users(:three) # developer
  end

  test "membership is readable from both sides" do
    AppMembership.create!(user: @user, managed_app: @app)

    assert_includes @app.members, @user
    assert_includes @user.managed_apps, @app
    assert_includes @app.member_ids, @user.id
  end

  test "the same person cannot be a member of the same app twice" do
    AppMembership.create!(user: @user, managed_app: @app)

    assert_raises(ActiveRecord::RecordNotUnique) do
      AppMembership.insert!({ user_id: @user.id, managed_app_id: @app.id, created_at: Time.current })
    end
  end

  test "membership rows disappear when the app is deleted" do
    AppMembership.create!(user: @user, managed_app: @app)

    @app.destroy

    assert_equal 0, AppMembership.where(managed_app_id: @app.id).count
  end

  test "deactivating a user does not affect membership rows, since deactivation is not deletion" do
    AppMembership.create!(user: @user, managed_app: @app)

    @user.deactivate!

    assert_includes @app.reload.members, @user
  end
end
