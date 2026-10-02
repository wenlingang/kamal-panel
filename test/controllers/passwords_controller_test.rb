require "test_helper"

class PasswordsControllerTest < ActionDispatch::IntegrationTest
  setup { @user = User.take }

  test "new" do
    get new_password_path
    assert_response :success
  end

  test "create" do
    post passwords_path, params: { email_address: @user.email_address }
    assert_enqueued_email_with PasswordsMailer, :reset, args: [ @user ]
    assert_redirected_to new_session_path

    follow_redirect!
    assert_notice "重置说明已发送"
  end

  test "create for an unknown user redirects but sends no mail" do
    post passwords_path, params: { email_address: "missing-user@example.com" }
    assert_enqueued_emails 0
    assert_redirected_to new_session_path

    follow_redirect!
    assert_notice "重置说明已发送"
  end

  test "edit" do
    get edit_password_path(@user.password_reset_token)
    assert_response :success
  end

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

  test "update with non matching passwords" do
    token = @user.password_reset_token
    assert_no_changes -> { @user.reload.password_digest } do
      put password_path(token),
          params: { password: "brandnew123", password_confirmation: "brandnew999" }
      assert_redirected_to edit_password_path(token)
    end

    follow_redirect!
    assert_notice "重复密码与密码不匹配"
  end

  # A too-short password and a mismatch between the two entries are two kinds of error, and the
  # messages must be distinguishable -- previously every failure here was reported as "the two
  # passwords don't match", and the person changing the password would retry again and again
  # following the wrong message.
  test "update with too short password" do
    token = @user.password_reset_token
    assert_no_changes -> { @user.reload.password_digest } do
      put password_path(token), params: { password: "short7c", password_confirmation: "short7c" }
      assert_redirected_to edit_password_path(token)
    end

    follow_redirect!
    assert_notice "密码过短"
  end

  private
    def assert_notice(text)
      assert_select "div", /#{text}/
    end
end
