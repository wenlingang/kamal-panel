require "application_system_test_case"

class RoleVisibilityTest < ApplicationSystemTestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  def sign_in_as_role(role)
    user = User.create!(email_address: "#{role}@example.com", password: "secret123456", role: role)
    sign_in_as(user)
  end

  # 这个文件测的是"角色决定按钮是否可见"，不是 KamalLock 真实读锁的行为
  # ——那部分由 test/services/kamal_lock_test.rb 用真实的 fake SSH host
  # 单独覆盖。之前这里给 fixture 配了一份真实可用的 SSH 凭据，只是为了
  # 让 managed_apps#show 里真实调用的 KamalLock 能读到"未锁定"，从而不
  # 挡住按钮——但这样一来，一个角色可见性测试就顺带变成了一次 SSH
  # 连通性测试：fake host 没起来、网络抖动，这个测试就会失败，而失败
  # 原因和"角色"毫无关系，下一个看到它变红的人会去错的地方排查
  # （task-5 review 的 Important）。所以这里直接 stub KamalLock#status，
  # 不依赖任何真实 SSH 连接。
  #
  # 不用 Minitest::Mock 的 Object#stub：minitest 6（本项目所用版本）把
  # Mock 拆进了一个独立 gem，默认不随 minitest 一起装
  # （`require "minitest/mock"` 直接 LoadError），引入它需要改
  # Gemfile——这条依赖变化超出了这次修复的范围。改用最基本的手法：临时
  # 重定义 KamalLock#status，用完（无论是否抛出异常）都还原成原方法，
  # 不留全局副作用。
  def visit_show_as_unlocked
    original_status = KamalLock.instance_method(:status)
    KamalLock.define_method(:status) { { locked: false, details: nil, error: nil } }
    yield
  ensure
    KamalLock.define_method(:status, original_status)
  end

  test "ops 看不到任何操作按钮" do
    sign_in_as_role("ops")
    visit_show_as_unlocked { visit managed_app_path(@app) }

    assert_text "blog"
    assert_no_button "启动"
    assert_no_text "停止"
    assert_no_text "回滚"
  end

  test "admin 看得到操作按钮" do
    sign_in_as_role("admin")
    visit_show_as_unlocked { visit managed_app_path(@app) }

    # 曾经这里断言的是占位按钮上的 [data-action-button]——那些按钮
    # 没有表单也没有处理器（见 Task 12 验收）。现在断言真的能提交的控件。
    assert_button "启动"
    assert_selector "details.stop-app summary", text: "停止"
    assert_text "回滚"
  end

  test "ops 在应用列表页看不到接入入口" do
    sign_in_as_role("ops")
    visit managed_apps_path

    assert_no_link "接入一个应用"
  end

  test "admin 在应用列表页看得到接入入口" do
    sign_in_as_role("admin")
    visit managed_apps_path

    assert_link "接入一个应用"
  end

  test "ops 在总览页（无应用时）看不到接入入口" do
    ManagedApp.destroy_all
    sign_in_as_role("ops")
    visit overview_path

    assert_no_link "接入一个"
  end
end
