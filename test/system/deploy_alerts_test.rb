require "application_system_test_case"

class DeployAlertsTest < ApplicationSystemTestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    sign_in_as(User.create!(email_address: "v@example.com", password: "secret123456",
                            role: "ops"))
  end

  test "上报成功但观测不到时详情页挂出告警，观测到之后自动消失" do
    event = DeployEvent.create!(managed_app: @app, version: "aaaaaaa", source: "hook",
                                succeeded_at: 5.minutes.ago)

    visit managed_app_path(@app)
    assert_text "未在任何机器上观测到"

    event.update!(observed_at: 1.minute.ago)

    visit managed_app_path(@app)
    assert_no_text "未在任何机器上观测到"
  end
end
