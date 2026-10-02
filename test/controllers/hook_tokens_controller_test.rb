require "test_helper"

class HookTokensControllerTest < ActionDispatch::IntegrationTest
  setup do
    @managed_app = ManagedApp.create!(name: "blog",
                                      config_yaml: file_fixture("simple_deploy.yml").read,
                                      destination: "production")
  end

  # The permission shape on this path differs from elsewhere: a class macro can't get at the app
  # that params[:managed_app_id] points to in before_action, so the check lives in the method body
  # (require_permission! + return if performed?). If someone ever deletes `return if performed?`,
  # the redirect is still issued but the token has already been reset -- so the rejection cases
  # below assert that the digest is unchanged, not just where the redirect went.
  test "developer can regenerate the report token for an app they own" do
    AppMembership.create!(user: users(:three), managed_app: @managed_app)
    sign_in_as users(:three)

    post managed_app_hook_token_path(@managed_app)

    assert_redirected_to managed_app_path(@managed_app)
    assert flash[:hook_token].present?, "The plaintext token appears only in this one flash"
    assert @managed_app.reload.hook_reporting_enabled?
  end

  test "rejects a developer who does not own the app and leaves its token untouched" do
    @managed_app.regenerate_hook_token!
    digest_before = @managed_app.reload.hook_token_digest

    sign_in_as users(:three)

    post managed_app_hook_token_path(@managed_app)

    assert_redirected_to root_path
    assert_equal "没有权限执行该操作", flash[:alert]
    assert_nil flash[:hook_token]
    assert_equal digest_before, @managed_app.reload.hook_token_digest,
      "A rejected request must never invalidate the token currently in use in production"
  end

  test "rejects ops and leaves the app's token untouched" do
    @managed_app.regenerate_hook_token!
    digest_before = @managed_app.reload.hook_token_digest

    sign_in_as users(:one)

    post managed_app_hook_token_path(@managed_app)

    assert_redirected_to root_path
    assert_equal digest_before, @managed_app.reload.hook_token_digest
  end

  test "admin can regenerate the report token and the old one is invalidated immediately" do
    @managed_app.regenerate_hook_token!
    digest_before = @managed_app.reload.hook_token_digest

    sign_in_as users(:two)

    post managed_app_hook_token_path(@managed_app)

    assert_redirected_to managed_app_path(@managed_app)
    assert flash[:hook_token].present?
    refute_equal digest_before, @managed_app.reload.hook_token_digest
  end
end
