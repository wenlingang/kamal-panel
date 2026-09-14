require "application_system_test_case"

class UnreachableHostTest < ApplicationSystemTestCase
  setup do
    Rails.cache.clear # cached_app_hosts 缓存键含 id，SQLite 回滚后可能复用 id

    @app = ManagedApp.create!(
      name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )

    sign_in_as(User.create!(email_address: "ops@example.com", password: "secret123456"))
  end

  test "失联的机器显示上次已知状态，而不是空白" do
    Observation.create!(
      managed_app: @app, host: "10.0.0.1", role: "web",
      container_name: "blog-web-production-aaaaaaa", version: "aaaaaaa",
      docker_status: "running", reachable: true, observed_at: 10.minutes.ago
    )
    Observation.create!(
      managed_app: @app, host: "10.0.0.1", reachable: false,
      error: "Net::SSH::ConnectionTimeout", observed_at: Time.current
    )

    visit managed_app_path(@app)

    assert_text "失联"
    assert_text "aaaaaaa", count: 1
    assert_text "前的状态"
  end
end
