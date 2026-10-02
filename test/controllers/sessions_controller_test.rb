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

  test "new" do
    get new_session_path
    assert_response :success
  end

  test "create with valid credentials" do
    post session_path, params: { email_address: @user.email_address, password: "password" }

    assert_redirected_to root_path
    assert cookies[:session_id]
  end

  test "create with invalid credentials" do
    post session_path, params: { email_address: @user.email_address, password: "wrong" }

    assert_response :unprocessable_entity
    assert_nil cookies[:session_id]
  end

  test "destroy" do
    sign_in_as(User.take)

    delete session_path

    assert_redirected_to new_session_path
    assert_empty cookies[:session_id]
  end

  test "redirects to the sign-in page when visiting the overview while signed out" do
    get root_path
    assert_redirected_to new_session_path
  end

  test "allows visiting the overview after signing in" do
    User.create!(email_address: "login-check@example.com", password: "secret123456")
    post session_path, params: { email_address: "login-check@example.com", password: "secret123456" }

    get root_path
    assert_response :success
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

  # The auth pages use a centered-card layout and render flash inside the card themselves. The
  # layout, though, renders it for [all] pages
  # -- so on login failure the same sentence appears twice: once stuck at the very top of the page, left-aligned,
  # full-width (that style is meant for the wide container of inner pages, and is completely out of
  # place on a centered card), and once inside the card.
  test "the sign-in failure notice appears only once, inside the card" do
    post session_path, params: { email_address: "me@example.com", password: "wrong" }

    assert_select ".flash-alert", count: 1
    assert_select ".auth-card .flash-alert"
  end

  test "signed-out pages do not render the layout's copy of the flash" do
    post session_path, params: { email_address: "me@example.com", password: "wrong" }

    assert_select "main.page > .flash", count: 0
  end

  # The redirect path still exists (rate limiting), and it also must not show two copies of the
  # flash.
  test "the rate-limit notice also appears only once" do
    11.times { post session_path, params: { email_address: "me@example.com", password: "wrong" } }
    follow_redirect!

    assert_select ".flash-alert", count: 1
    assert_select ".auth-card .flash-alert", text: /请稍后再试/
  end

  # A failed login shouldn't also clear the email the person typed -- retyping the email is pure
  # punishment, and what's wrong is usually just the password. The view already has value:
  # params[:email_address], but create redirects, so the params are gone by the redirect and that
  # line has always been dead.
  test "a failed sign-in keeps the email address that was entered" do
    post session_path, params: { email_address: "me@example.com", password: "wrong" }

    assert_response :unprocessable_entity
    assert_select "input[name=email_address][value=?]", "me@example.com"
  end

  test "a failed sign-in still shows a notice" do
    post session_path, params: { email_address: "me@example.com", password: "wrong" }

    assert_select ".auth-card .flash-alert", text: /邮箱地址或密码不正确/
    assert_select ".flash-alert", count: 1
  end

  # The password isn't refilled: the browser's password manager fills it itself, and rendering it
  # into HTML means it would appear in the page source and anywhere that captures this response.
  test "a failed sign-in does not refill the password" do
    post session_path, params: { email_address: "me@example.com", password: "wrong" }

    assert_select "input[name=password][value]", count: 0
  end
end
