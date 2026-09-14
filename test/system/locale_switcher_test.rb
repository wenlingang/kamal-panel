require "application_system_test_case"

# 下拉「选了就提交」这件事只有真实浏览器验得了：集成测试里 select 的 change
# 事件根本不会发生，Stimulus 也没跑。
class LocaleSwitcherTest < ApplicationSystemTestCase
  setup do
    @admin = User.create!(email_address: "switcher@example.com",
                          password: "secret123456", role: "admin")
  end

  test "在下拉里选英文，整页立刻变成英文并记住偏好" do
    sign_in_as @admin
    assert_text "总览"

    select "EN", from: "locale"

    assert_text "Overview"
    assert_equal "en", @admin.reload.locale
  end

  test "有 JS 时那个退路按钮是藏起来的" do
    sign_in_as @admin

    assert_no_selector ".chrome-locale input[type=submit]", visible: true
  end
end
