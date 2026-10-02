require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  # sessions#create 有 rate_limit（10 次 / 3 分钟，按 IP 计），计数存在
  # Rails.cache 里，而集成测试之间不会自己清。这个文件里既有"登录失败"又有
  # "被限流"的用例，不清的话后者会把前者顶过阈值，失败原因看起来像"登录逻辑
  # 坏了"，其实只是上一条用例攒下的计数。application_system_test_case.rb
  # 早就因为同样的原因每个用例前清一次。
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

  # 认证页是居中卡片版式，自己在卡片里渲染 flash。而 layout 又对【所有】页面
  # 渲染一遍——于是登录失败时同一句话出现两次：一次贴在页面最顶上、左对齐、
  # 通栏（那是给内页的宽容器准备的样式，在居中卡片上完全错位），一次在卡片里。
  test "登录失败的提示只出现一次，且在卡片里" do
    post session_path, params: { email_address: "me@example.com", password: "wrong" }

    assert_select ".flash-alert", count: 1
    assert_select ".auth-card .flash-alert"
  end

  test "未登录页面不渲染 layout 那一份 flash" do
    post session_path, params: { email_address: "me@example.com", password: "wrong" }

    assert_select "main.page > .flash", count: 0
  end

  # 重定向那条路仍然存在（限流），它同样不能出现两份 flash。
  test "被限流时提示也只出现一次" do
    11.times { post session_path, params: { email_address: "me@example.com", password: "wrong" } }
    follow_redirect!

    assert_select ".flash-alert", count: 1
    assert_select ".auth-card .flash-alert", text: /请稍后再试/
  end

  # 登录失败不该把人填的邮箱也一起清掉——重打一遍邮箱是纯粹的惩罚，而错的
  # 通常只是密码。视图里本来就写着 value: params[:email_address]，只是 create
  # 走的是 redirect，参数在重定向里就没了，那一行一直是死的。
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

  # 密码不回填：浏览器的密码管理器会自己填，而把它渲染进 HTML 等于让它出现在
  # 页面源码、以及任何抓到这次响应的地方。
  test "登录失败不回填密码" do
    post session_path, params: { email_address: "me@example.com", password: "wrong" }

    assert_select "input[name=password][value]", count: 0
  end
end
