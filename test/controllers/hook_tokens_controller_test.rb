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
  test "名下 developer 能重新生成上报 token" do
    AppMembership.create!(user: users(:three), managed_app: @managed_app)
    sign_in_as users(:three)

    post managed_app_hook_token_path(@managed_app)

    assert_redirected_to managed_app_path(@managed_app)
    assert flash[:hook_token].present?, "明文 token 只在这一次的 flash 里出现"
    assert @managed_app.reload.hook_reporting_enabled?
  end

  test "非名下的 developer 被拒，且该应用的 token 原封不动" do
    @managed_app.regenerate_hook_token!
    digest_before = @managed_app.reload.hook_token_digest

    sign_in_as users(:three)

    post managed_app_hook_token_path(@managed_app)

    assert_redirected_to root_path
    assert_equal "没有权限执行该操作", flash[:alert]
    assert_nil flash[:hook_token]
    assert_equal digest_before, @managed_app.reload.hook_token_digest,
      "被拒的请求绝不能顺手把线上正在用的 token 作废掉"
  end

  test "ops 被拒，且该应用的 token 原封不动" do
    @managed_app.regenerate_hook_token!
    digest_before = @managed_app.reload.hook_token_digest

    sign_in_as users(:one)

    post managed_app_hook_token_path(@managed_app)

    assert_redirected_to root_path
    assert_equal digest_before, @managed_app.reload.hook_token_digest
  end

  test "admin 能重新生成上报 token，旧的当场失效" do
    @managed_app.regenerate_hook_token!
    digest_before = @managed_app.reload.hook_token_digest

    sign_in_as users(:two)

    post managed_app_hook_token_path(@managed_app)

    assert_redirected_to managed_app_path(@managed_app)
    assert flash[:hook_token].present?
    refute_equal digest_before, @managed_app.reload.hook_token_digest
  end
end
