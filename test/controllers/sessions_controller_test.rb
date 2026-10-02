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

  test "未登录访问总览会跳到登录页" do
    get root_path
    assert_redirected_to new_session_path
  end

  test "登录后可访问总览" do
    User.create!(email_address: "login-check@example.com", password: "secret123456")
    post session_path, params: { email_address: "login-check@example.com", password: "secret123456" }

    get root_path
    assert_response :success
  end

  test "停用的用户无法登录" do
    user = User.create!(email_address: "gone@example.com", password: "secret123456", role: "ops")
    user.deactivate!

    post session_path, params: { email_address: "gone@example.com", password: "secret123456" }

    assert_response :unprocessable_entity
    assert_equal "邮箱地址或密码不正确。", flash[:alert],
      "不要告诉对方「这个账号被停用了」——那等于向未认证的人确认这个邮箱存在"
  end

  test "已登录的用户被停用后，下一次请求就失效" do
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
  test "登录失败的提示只出现一次，且在卡片里" do
    post session_path, params: { email_address: "me@example.com", password: "wrong" }

    assert_select ".flash-alert", count: 1
    assert_select ".auth-card .flash-alert"
  end

  test "未登录页面不渲染 layout 那一份 flash" do
    post session_path, params: { email_address: "me@example.com", password: "wrong" }

    assert_select "main.page > .flash", count: 0
  end

  # The redirect path still exists (rate limiting), and it also must not show two copies of the
  # flash.
  test "被限流时提示也只出现一次" do
    11.times { post session_path, params: { email_address: "me@example.com", password: "wrong" } }
    follow_redirect!

    assert_select ".flash-alert", count: 1
    assert_select ".auth-card .flash-alert", text: /请稍后再试/
  end

  # A failed login shouldn't also clear the email the person typed -- retyping the email is pure
  # punishment, and what's wrong is usually just the password. The view already has value:
  # params[:email_address], but create redirects, so the params are gone by the redirect and that
  # line has always been dead.
  test "登录失败保留已填的邮箱地址" do
    post session_path, params: { email_address: "me@example.com", password: "wrong" }

    assert_response :unprocessable_entity
    assert_select "input[name=email_address][value=?]", "me@example.com"
  end

  test "登录失败仍然给出提示" do
    post session_path, params: { email_address: "me@example.com", password: "wrong" }

    assert_select ".auth-card .flash-alert", text: /邮箱地址或密码不正确/
    assert_select ".flash-alert", count: 1
  end

  # The password isn't refilled: the browser's password manager fills it itself, and rendering it
  # into HTML means it would appear in the page source and anywhere that captures this response.
  test "登录失败不回填密码" do
    post session_path, params: { email_address: "me@example.com", password: "wrong" }

    assert_select "input[name=password][value]", count: 0
  end
end
