require "test_helper"

class AccountPasswordsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear # update is rate limited and the counter lives in the cache
    @user = users(:one)
    sign_in_as @user
  end

  test "changes the password, signs out other devices and keeps this one" do
    other = @user.sessions.create!
    current = Current.session

    patch account_password_path, params: { current_password: "password", password: "brand-new-pass",
                                           password_confirmation: "brand-new-pass" }

    assert_redirected_to root_path
    assert @user.reload.authenticate("brand-new-pass")
    assert_not Session.exists?(other.id), "Other devices must be signed out"
    assert Session.exists?(current.id), "The session doing the change stays signed in"

    log = AuditLog.order(:id).last
    assert_equal "user.change_password", log.action_name
    assert_equal @user, log.target_user
  end

  test "a wrong current password changes nothing" do
    patch account_password_path, params: { current_password: "wrong", password: "brand-new-pass",
                                           password_confirmation: "brand-new-pass" }

    assert_response :unprocessable_entity
    assert_select ".flash-alert", text: /#{I18n.t("flash.password.wrong_current", locale: :"zh-CN")}|#{I18n.t("flash.password.wrong_current", locale: :en)}/
    assert @user.reload.authenticate("password")
  end

  test "leaving out the confirmation does not skip it" do
    patch account_password_path, params: { current_password: "password", password: "brand-new-pass" }

    assert_response :unprocessable_entity
    assert @user.reload.authenticate("password")
  end
end
