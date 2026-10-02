require "test_helper"

# Changing your own UI language is [not] user management. User management is admin-only, while
# everyone must be able to change language
# -- if it were a field of UsersController#update, developers and ops could never
# change their own language, and they are exactly the largest group of users.
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

  # There is no "change someone else's language" path: the controller doesn't take a user id at all,
  # so what's asserted here is that passing an extra id param can't affect anyone else.
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

  # Use the home page rather than the users page: users(:one) is ops, opening /users would redirect,
  # and the header wouldn't render at all -- that assertion would be a false green, passing whether
  # or not the switcher is right. So each case first asserts that the header is actually there, then
  # asserts the switcher.
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

  # It must also work without JS: the select doesn't submit the form by itself. With JS this button
  # is hidden by the auto-submit controller, replaced by "go as soon as you pick".
  test "下拉旁边有一个真的提交按钮，作为没有 JS 时的退路" do
    sign_in_as users(:one)

    get root_path

    assert_select ".chrome-locale form[method=post] input[type=submit]"
    assert_select ".chrome-locale form input[name=_method][value=patch]", count: 1
  end

  # With only one selectable language, render nothing: a switcher with a single option would make
  # people think there are other choices. The first four batches of design 13 live in exactly this
  # state -- the mechanism is testable, the entry point isn't exposed.
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
