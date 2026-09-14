require "test_helper"

# 面板的界面文案是中文的，但 time_ago_in_words、校验失败信息这类文案来自
# Rails 而不是本仓库的模板。少了 rails-i18n 或者 default_locale 被改回 :en，
# 页面不会报错，只会悄悄混出英文（"less than a minute前"）——这类静默退化
# 只能靠测试挡住。
class I18nLocaleTest < ActiveSupport::TestCase
  include ActionView::Helpers::DateHelper

  test "默认 locale 是 zh-CN" do
    assert_equal :"zh-CN", I18n.default_locale
    assert_equal :"zh-CN", I18n.locale
  end

  test "缺译文时回落到英文而不是渲染 translation missing" do
    # fallbacks 若配成 true，回落目标就是 default_locale 本身，等于没有回落。
    assert_equal "Hello world", I18n.t("hello")
  end

  test "相对时间是中文" do
    assert_equal "7分钟", time_ago_in_words(7.minutes.ago)
    assert_equal "大约3小时", time_ago_in_words(3.hours.ago)
    assert_equal "2天", time_ago_in_words(2.days.ago)
  end

  test "校验失败信息连同属性名都是中文" do
    app = ManagedApp.new
    app.valid?

    assert_includes app.errors.full_messages, "名称不能为空"
    assert_includes app.errors.full_messages, "deploy.yml 原文不能为空"
  end

  test "重置密码邮件是中文" do
    user = User.create!(email_address: "i18n@example.com", password: "secret123456")
    mail = PasswordsMailer.reset(user)

    assert_equal "重置你的 Kamal Panel 密码", mail.subject
    assert_match "打开重置页面", mail.html_part.body.to_s
    assert_match "后失效", mail.text_part.body.to_s
  end
end
