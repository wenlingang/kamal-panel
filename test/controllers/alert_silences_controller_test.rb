require "test_helper"

class AlertSilencesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @managed_app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production")
  end

  def sign_in(role)
    user = User.create!(email_address: "#{role}@example.com", password: "secret123456", role:)
    post session_path, params: { email_address: "#{role}@example.com", password: "secret123456" }
    user
  end

  test "admin silences one app for an hour, then ends it early" do
    sign_in("admin")
    post alert_silences_path, params: { alert_silence: { managed_app_id: @managed_app.id, duration: "60", reason: "db upgrade",
                                                         starts_at: 1.minute.ago.strftime("%Y-%m-%dT%H:%M") } }
    silence = AlertSilence.sole
    assert_redirected_to alert_silences_path
    assert_in_delta 60.minutes, silence.ends_at - silence.starts_at, 1
    assert AlertSilence.silenced?(@managed_app.id)

    get alert_silences_path
    assert_select "td", text: "db upgrade"

    delete alert_silence_path(silence)
    assert_not AlertSilence.silenced?(@managed_app.id)
    assert_equal %w[alert_silence.create alert_silence.end], AuditLog.order(:id).last(2).map(&:action_name)
  end

  test "only an admin silences every app; ops can't silence an app" do
    sign_in("developer")
    post alert_silences_path, params: { alert_silence: { managed_app_id: "", duration: "60" } }
    assert_empty AlertSilence.all

    delete session_path
    sign_in("ops")
    post alert_silences_path, params: { alert_silence: { managed_app_id: @managed_app.id, duration: "60" } }
    assert_empty AlertSilence.all
  end
end
