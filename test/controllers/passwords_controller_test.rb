require "test_helper"

class PasswordsControllerTest < ActionDispatch::IntegrationTest
  setup { @user = User.take }

  test "edit with invalid password reset token" do
    get edit_password_path("invalid token")
    assert_redirected_to new_password_path

    follow_redirect!
    assert_notice "重置链接无效"
  end

  test "update" do
    assert_changes -> { @user.reload.password_digest } do
      put password_path(@user.password_reset_token),
          params: { password: "brandnew123", password_confirmation: "brandnew123" }
      assert_redirected_to new_session_path
    end

    follow_redirect!
    assert_notice "密码已重置"
  end

  private
    def assert_notice(text)
      assert_select "div", /#{text}/
    end
end
