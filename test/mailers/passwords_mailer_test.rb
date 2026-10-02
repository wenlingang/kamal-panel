require "test_helper"

# 邮件按【收件人】的语言渲染，不是按发信那一刻的 I18n.locale。
#
# 这条是独立于请求的路径：deliver_later 在后台任务里执行，那里没有请求上下文，
# ApplicationController 的 around_action 完全帮不上忙。所以它必须自己负责，
# 也必须自己有测试——否则一个 admin 在中文界面上给英文同事建号，对方收到的
# 会是一封中文邮件，而没有任何测试会因此变红。
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

  # 发信那一刻界面是什么语言不影响收件人收到什么。
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
