require "test_helper"

# locale 的三级来源：用户偏好 → Accept-Language → 默认。
class LocalizationTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:two)
    # 页面上没有任何地方直接印出当前 locale，所以集成测试断言的是一条【确实
    # 会随 locale 变】的既有文案：审计动作名（设计 12 建的 audit.actions.*）。
    # 断言用户真正看到的东西，而不是内省 I18n.locale——后者在请求结束时已经
    # 被 around_action 还原，请求之后再去读它，读到的永远是默认值。
    AuditLog.record_access!(user: @admin, action_name: "user.deactivate",
                            target_user: users(:one))
  end

  test "登录用户的偏好决定语言" do
    @admin.update!(locale: "en")
    sign_in_as @admin

    get audit_logs_path

    assert_select "td", text: "Deactivate member"
  end

  # 偏好为空时落到第二级。这一条同时证明了请求头确实被读到了——它是
  # match_accept_language 那组单测之外，唯一能证明"接线接对了"的测试。
  test "没设偏好的登录用户跟 Accept-Language 走" do
    @admin.update!(locale: nil)
    sign_in_as @admin

    get audit_logs_path, headers: { "HTTP_ACCEPT_LANGUAGE" => "en-US,en;q=0.9" }

    assert_select "td", text: "Deactivate member"
  end

  test "偏好优先于 Accept-Language" do
    @admin.update!(locale: "zh-CN")
    sign_in_as @admin

    get audit_logs_path, headers: { "HTTP_ACCEPT_LANGUAGE" => "en-US,en;q=0.9" }

    assert_select "td", text: "停用成员"
  end

  test "两级都拿不到时用默认语言" do
    @admin.update!(locale: nil)
    sign_in_as @admin

    get audit_logs_path

    assert_select "td", text: "停用成员"
  end

  # I18n.locale 是线程级全局状态。请求结束不还原的话，同一个线程服务下一个
  # 请求时会带着上一个用户的语言——这种串味在生产里极难复现，必须有测试盯着。
  test "请求结束后 I18n.locale 已还原" do
    @admin.update!(locale: "en")
    sign_in_as @admin

    get audit_logs_path

    assert_equal I18n.default_locale, I18n.locale
  end
end

# 纯函数，单独测。不需要请求、不需要登录，所以可以把各种畸形头部穷举干净。
class LocalizationAcceptLanguageTest < ActiveSupport::TestCase
  def match(header) = Localization.match_accept_language(header)

  test "认出英文" do
    assert_equal :en, match("en-US,en;q=0.9")
  end

  test "任何 zh 变体都算简体中文" do
    assert_equal :"zh-CN", match("zh-CN,zh;q=0.9")
    assert_equal :"zh-CN", match("zh-TW")
    assert_equal :"zh-CN", match("zh")
  end

  test "取第一个认得出的标签，不做权重协商" do
    assert_equal :en, match("fr-FR,fr;q=0.9,en;q=0.8")
  end

  test "一个都认不出时返回 nil，交给调用方回落" do
    assert_nil match("fr-FR,fr;q=0.9")
  end

  test "空头部返回 nil" do
    assert_nil match(nil)
    assert_nil match("")
  end
end
