require "test_helper"

# 改自己的界面语言【不是】人员管理。人员管理 admin 独占，语言人人都得能改
# ——把它当成 UsersController#update 的一个字段的话，developer 和 ops 就永远
# 换不了自己的语言，而他们恰恰是人数最多的那部分用户。
class LocalesControllerTest < ActionDispatch::IntegrationTest
  test "任何已登录角色都能改自己的语言" do
    [ users(:one), users(:two), users(:three) ].each do |user|
      sign_in_as user

      patch locale_path, params: { locale: "en" }

      assert_equal "en", user.reload.locale
      sign_out
    end
  end

  test "未登录改不了" do
    patch locale_path, params: { locale: "en" }

    assert_redirected_to new_session_path
  end

  # 没有「帮别人换语言」这条路径：控制器根本不收 user id，所以这里断言的是
  # 多给一个 id 参数也影响不到别人。
  test "只改得了自己" do
    sign_in_as users(:one)

    patch locale_path, params: { locale: "en", user_id: users(:two).id, id: users(:two).id }

    assert_equal "en", users(:one).reload.locale
    assert_nil users(:two).reload.locale
  end

  test "不可用的语言被拒，原来的偏好不变" do
    users(:one).update!(locale: "zh-CN")
    sign_in_as users(:one)

    patch locale_path, params: { locale: "fr" }

    assert_equal "zh-CN", users(:one).reload.locale
  end

  test "改完回到来的那一页" do
    sign_in_as users(:one)

    patch locale_path, params: { locale: "en" }, headers: { "HTTP_REFERER" => users_path }

    assert_redirected_to users_path
  end

  # 用首页而不是人员页：users(:one) 是 ops，开 /users 会被重定向，页头压根
  # 不渲染——那样断言是假绿，无论切换器写对写错都会通过。所以每条都先断言
  # 页头确实在，再断言切换器。
  test "页头的切换器是个下拉，每种可选语言一个选项" do
    sign_in_as users(:one)

    get root_path

    assert_select ".chrome-user"
    assert_select ".chrome-locale select[name=locale] option",
                  count: User::SELECTABLE_LOCALES.size
  end

  test "下拉里选中的是当前语言" do
    users(:one).update!(locale: "en")
    sign_in_as users(:one)

    get root_path

    assert_select ".chrome-locale select option[selected][value=en]"
  end

  # 没有 JS 时也得能切：select 自己不会提交表单。有 JS 时这个按钮由
  # auto-submit 控制器藏起来，换成"选了就走"。
  test "下拉旁边有一个真的提交按钮，作为没有 JS 时的退路" do
    sign_in_as users(:one)

    get root_path

    assert_select ".chrome-locale form[method=post] input[type=submit]"
    assert_select ".chrome-locale form input[name=_method][value=patch]", count: 1
  end

  # 只有一种可选语言时整个不渲染：给一个只有一个选项的切换器，等于让人以为
  # 还有别的可选。设计 13 的前四批就活在这个状态里——机制可测、入口不暴露。
  test "只有一种可选语言时页头不出现切换器" do
    with_selectable_locales(%w[zh-CN]) do
      sign_in_as users(:one)

      get root_path

      assert_select ".chrome-user"
      assert_select ".chrome-locale", count: 0
    end
  end


  private
    def with_selectable_locales(locales)
      original = User::SELECTABLE_LOCALES
      User.send(:remove_const, :SELECTABLE_LOCALES)
      User.const_set(:SELECTABLE_LOCALES, locales.freeze)
      yield
    ensure
      User.send(:remove_const, :SELECTABLE_LOCALES)
      User.const_set(:SELECTABLE_LOCALES, original)
    end
end
