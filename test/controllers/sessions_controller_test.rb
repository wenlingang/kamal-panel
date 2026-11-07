require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  # sessions#create has a rate_limit (10 per 3 minutes, per IP), and the counter is stored in
  # Rails.cache, which integration tests don't clear between themselves. This file has both "login
  # failed" and "rate limited" cases; without clearing, the latter would push the former over the
  # threshold, and the failure would look like "the login logic is broken" when it's really just the
  # count accumulated by the previous case. application_system_test_case.rb has long cleared it
  # before every case for the same reason.
  setup do
    Rails.cache.clear
    @user = User.take
  end

  test "create with valid credentials" do
    post session_path, params: { email_address: @user.email_address, password: "password" }

    assert_redirected_to root_path
    assert cookies[:session_id]
  end

  test "the session expires on the server, whatever the cookie says" do
    post session_path, params: { email_address: @user.email_address, password: "password" }
    session = @user.sessions.order(:id).last
    assert_in_delta Session::UNREMEMBERED_FOR.from_now, session.expires_at, 5

    # A browser restoring its last session brings a "session" cookie back; the row decides.
    session.update!(expires_at: 1.minute.ago)
    get root_path
    assert_redirected_to new_session_path
  end

  test "create with invalid credentials" do
    post session_path, params: { email_address: @user.email_address, password: "wrong" }

    assert_response :unprocessable_entity
    assert_nil cookies[:session_id]
  end

  test "a deactivated user cannot sign in" do
    user = User.create!(email_address: "gone@example.com", password: "secret123456", role: "ops")
    user.deactivate!

    post session_path, params: { email_address: "gone@example.com", password: "secret123456" }

    assert_response :unprocessable_entity
    assert_equal "邮箱地址或密码不正确。", flash[:alert],
      "do not tell them 'this account is deactivated' -- that would confirm to an unauthenticated person that the email exists"
  end

  test "a signed-in user is signed out on the next request after being deactivated" do
    user = User.create!(email_address: "gone@example.com", password: "secret123456", role: "ops")
    sign_in_as user
    get root_path
    assert_response :success

    user.deactivate!

    get root_path
    assert_redirected_to new_session_path
  end
end
