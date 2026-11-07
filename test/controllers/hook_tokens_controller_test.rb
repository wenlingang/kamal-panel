require "test_helper"

class HookTokensControllerTest < ActionDispatch::IntegrationTest
  setup do
    @managed_app = ManagedApp.create!(name: "blog",
                                      config_yaml: file_fixture("simple_deploy.yml").read,
                                      destination: "production")
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
end
