require "test_helper"

# Changing your own UI language is [not] user management. User management is admin-only, while
# everyone must be able to change language
# -- if it were a field of UsersController#update, developers and ops could never
# change their own language, and they are exactly the largest group of users.
class LocalesControllerTest < ActionDispatch::IntegrationTest
  test "lets any signed-in role change their own locale" do
    [ users(:one), users(:two), users(:three) ].each do |user|
      sign_in_as user

      patch locale_path, params: { locale: "en" }

      assert_equal "en", user.reload.locale
      sign_out
    end
  end

  test "rejects locale changes when signed out" do
    patch locale_path, params: { locale: "en" }

    assert_redirected_to new_session_path
  end

  # There is no "change someone else's language" path: the controller doesn't take a user id at all,
  # so what's asserted here is that passing an extra id param can't affect anyone else.
  test "only lets a user change their own locale" do
    sign_in_as users(:one)

    patch locale_path, params: { locale: "en", user_id: users(:two).id, id: users(:two).id }

    assert_equal "en", users(:one).reload.locale
    assert_nil users(:two).reload.locale
  end

  test "rejects an unavailable locale and keeps the previous preference" do
    users(:one).update!(locale: "zh-CN")
    sign_in_as users(:one)

    patch locale_path, params: { locale: "fr" }

    assert_equal "zh-CN", users(:one).reload.locale
  end

  test "redirects back to the originating page after the change" do
    sign_in_as users(:one)

    patch locale_path, params: { locale: "en" }, headers: { "HTTP_REFERER" => users_path }

    assert_redirected_to users_path
  end

  # Use the home page rather than the users page: users(:one) is ops, opening /users would redirect,
  # and the header wouldn't render at all -- that assertion would be a false green, passing whether
  # or not the switcher is right. So each case first asserts that the header is actually there, then
  # asserts the switcher.
  test "the account menu offers one button per locale, each named in its own language" do
    sign_in_as users(:one)

    get root_path

    assert_select ".account-menu summary .account-name"
    assert_select ".account-menu form[action=?] input[name=locale]", locale_path, count: User::SELECTABLE_LOCALES.size
    assert_select ".account-menu button[data-locale=en]", text: "English"
    assert_select ".account-menu button[data-locale=zh-CN]", text: "简体中文"
  end

  test "marks the current locale as pressed" do
    users(:one).update!(locale: "en")
    sign_in_as users(:one)

    get root_path

    assert_select ".account-menu button[data-locale=en][aria-pressed=true]"
    assert_select ".account-menu button[data-locale=zh-CN][aria-pressed=false]"
  end

  # Plain button_to forms: they work without JS, as PATCH like before.
  test "each locale button is a real PATCH form" do
    sign_in_as users(:one)

    get root_path

    assert_select ".account-menu form[method=post] input[name=_method][value=patch]",
                  count: User::SELECTABLE_LOCALES.size
  end

  # With only one selectable language, render nothing: a switcher with a single option would make
  # people think there are other choices. The first four batches of design 13 live in exactly this
  # state -- the mechanism is testable, the entry point isn't exposed.
  test "hides the language choice when only one locale is available" do
    with_selectable_locales(%w[zh-CN]) do
      sign_in_as users(:one)

      get root_path

      assert_select ".account-menu"
      assert_select ".account-menu button[data-locale]", count: 0
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
