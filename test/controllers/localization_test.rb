require "test_helper"

# The three-tier source of locale: user preference -> Accept-Language -> default.
class LocalizationTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:two)
    # Nothing on the page prints the current locale directly, so the integration test asserts an
    # existing string that [really varies with locale]: audit action names (audit.actions.* built in
    # design 12). Assert what the user actually sees, rather than introspecting I18n.locale -- the
    # latter has already been restored by around_action at the end of the request, so reading it
    # after the request always gives the default.
    AuditLog.record_access!(user: @admin, action_name: "user.deactivate",
                            target_user: users(:one))
  end

  test "signed-in user's preference determines the locale" do
    @admin.update!(locale: "en")
    sign_in_as @admin

    get audit_logs_path

    assert_select "td", text: "Deactivate member"
  end

  # When preference is empty it falls to the second tier. This also proves the request header is
  # really read -- apart from the match_accept_language unit tests, it's the only test proving "the
  # wiring is right".
  test "signed-in user without a preference follows Accept-Language" do
    @admin.update!(locale: nil)
    sign_in_as @admin

    get audit_logs_path, headers: { "HTTP_ACCEPT_LANGUAGE" => "en-US,en;q=0.9" }

    assert_select "td", text: "Deactivate member"
  end

  test "preference takes precedence over Accept-Language" do
    @admin.update!(locale: "zh-CN")
    sign_in_as @admin

    get audit_logs_path, headers: { "HTTP_ACCEPT_LANGUAGE" => "en-US,en;q=0.9" }

    assert_select "td", text: "停用成员"
  end

  test "falls back to the default locale when neither level yields one" do
    @admin.update!(locale: nil)
    sign_in_as @admin

    get audit_logs_path

    assert_select "td", text: "停用成员"
  end

  # I18n.locale is thread-level global state. If it isn't restored at the end of a request, the same
  # thread serving the next request carries over the previous user's language -- such
  # cross-contamination is extremely hard to reproduce in production, so a test must watch it.
  test "restores I18n.locale after the request" do
    @admin.update!(locale: "en")
    sign_in_as @admin

    get audit_logs_path

    assert_equal I18n.default_locale, I18n.locale
  end
end

# A pure function, tested on its own. Needs no request and no login, so all kinds of malformed
# headers can be exhausted.
class LocalizationAcceptLanguageTest < ActiveSupport::TestCase
  def match(header) = Localization.match_accept_language(header)

  test "recognizes English" do
    assert_equal :en, match("en-US,en;q=0.9")
  end

  test "treats any zh variant as Simplified Chinese" do
    assert_equal :"zh-CN", match("zh-CN,zh;q=0.9")
    assert_equal :"zh-CN", match("zh-TW")
    assert_equal :"zh-CN", match("zh")
  end

  test "picks the first recognizable tag without q-value negotiation" do
    assert_equal :en, match("fr-FR,fr;q=0.9,en;q=0.8")
  end

  test "returns nil when none is recognized, leaving fallback to the caller" do
    assert_nil match("fr-FR,fr;q=0.9")
  end

  test "returns nil for an empty header" do
    assert_nil match(nil)
    assert_nil match("")
  end
end
