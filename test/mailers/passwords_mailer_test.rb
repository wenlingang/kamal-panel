require "test_helper"

# The mail is rendered in the [recipient's] language, not in the I18n.locale at the moment of
# sending.
#
# This path is independent of the request: deliver_later runs in a background job, where there is no
# request context and ApplicationController's around_action can't help at all. So it must take care
# of this itself, and must have its own test -- otherwise an admin on the Chinese UI creating an
# account for an English-speaking colleague would have the colleague receive a Chinese email, and no
# test would go red because of it.
class PasswordsMailerTest < ActionMailer::TestCase
  test "按收件人的偏好渲染" do
    user = User.create!(email_address: "en@example.com", password: "secret123456", locale: "en")

    mail = PasswordsMailer.reset(user)

    assert_equal "Reset your Kamal Panel password", mail.subject
    assert_match "Open the reset page", mail.body.encoded
  end

  test "收件人没设偏好时用默认语言" do
    user = User.create!(email_address: "zh@example.com", password: "secret123456")

    mail = PasswordsMailer.reset(user)

    assert_equal "重置你的 Kamal Panel 密码", mail.subject
  end

  # What language the UI is in at the moment of sending doesn't affect what the recipient receives.
  test "不受发信时当前 locale 的影响" do
    user = User.create!(email_address: "en2@example.com", password: "secret123456", locale: "en")

    mail = I18n.with_locale(:"zh-CN") { PasswordsMailer.reset(user) }

    assert_equal "Reset your Kamal Panel password", mail.subject
  end

  test "渲染完不改动全局 locale" do
    user = User.create!(email_address: "en3@example.com", password: "secret123456", locale: "en")

    PasswordsMailer.reset(user).subject

    assert_equal I18n.default_locale, I18n.locale
  end
end
