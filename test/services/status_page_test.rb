require "test_helper"

class StatusPageTest < ActionDispatch::IntegrationTest
  setup do
    @managed_app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production")
  end

  def observe(health)
    at = Time.current
    Observation.create!(managed_app: @managed_app, host: "127.0.0.1", role: "web", reachable: true, version: "abc1234",
                        docker_status: "running", container_name: "blog-web-production-abc1234", health:, observed_at: at)
  end

  test "there is no status page until an app is listed on it" do
    get status_page_path
    assert_response :not_found
  end

  test "lists the app under its public name, with its days, and nothing internal" do
    @managed_app.update!(public_status: true, public_name: "Blog")
    observe("healthy")
    StatusPageSampleJob.perform_now
    observe("unhealthy")
    StatusPageSampleJob.perform_now

    sample = StatusSample.sole
    assert_equal [ 2, 1, 1 ], [ sample.total, sample.ok, sample.degraded ]

    get status_page_path
    assert_response :success
    assert_select ".status-app strong", text: "Blog"
    assert_select ".status-day", count: StatusPage::DAYS
    assert_no_match(/127\.0\.0\.1|abc1234|blog-web/, response.body)
  end

  test "the weekly summary goes out as one message per opted-in channel" do
    NotificationChannel.create!(name: "hook", kind: "webhook", target: "https://hooks.example.com/x", weekly_summary: true)
    headline, lines = WeeklySummary.new.build

    assert headline.present?
    assert lines.any?
    message = WeeklySummary.new.message
    assert_equal "summary", message.as_payload[:event]
  end
end
