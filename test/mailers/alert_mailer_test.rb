require "test_helper"

class AlertMailerTest < ActionMailer::TestCase
  setup do
    @message = Notifiers::Message.new(kind: "firing", state: "firing", rule_id: 1, rule_name: "不健康", condition: "unhealthy",
                                      app_id: 2, app_name: "blog", text: "有容器健康检查失败", started_at: Time.utc(2026, 11, 5, 8),
                                      fired_at: nil, resolved_at: nil, url: "https://panel.example.com/apps/2")
  end

  test "sends text and html with the title, the message and the link" do
    email = AlertMailer.notification(%w[ops@example.com], @message)

    assert_equal [ "ops@example.com" ], email.to
    assert_equal "[告警] 不健康 · blog", email.subject
    assert_includes email.text_part.body.to_s, "有容器健康检查失败"
    assert_includes email.text_part.body.to_s, "https://panel.example.com/apps/2"
    assert_includes email.html_part.body.to_s, %(href="https://panel.example.com/apps/2")
  end

  test "renders in the default locale whatever the current one is" do
    email = I18n.with_locale(:en) { AlertMailer.notification(%w[ops@example.com], @message) }

    assert_includes email.html_part.body.to_s, I18n.t("notifiers.open_panel", locale: :"zh-CN")
  end
end
