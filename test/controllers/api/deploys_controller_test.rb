require "test_helper"

class Api::DeploysControllerTest < ActionDispatch::IntegrationTest
  setup { Rails.cache.clear }

  setup do
    @managed_app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    @token = @managed_app.regenerate_hook_token!
  end

  def post_report(token: @token, **overrides)
    params = { phase: "succeeded", service: "blog", destination: "production",
               version: "aaaaaaa", performer: "ci", command: "deploy",
               recorded_at: Time.current.iso8601 }.merge(overrides)

    post "/api/deploys", params: params,
         headers: { "Authorization" => "Bearer #{token}" }
  end

  test "accepts a report with a known token and returns no content" do
    post_report

    assert_response :no_content
    assert_equal "", response.body
    assert_equal 1, @managed_app.deploy_events.count
  end

  test "rejects an unknown token with 401 and records nothing" do
    post_report(token: "nope")

    assert_response :unauthorized
    assert_equal 0, DeployEvent.count
  end

  test "rejects an invalid version with 422" do
    post_report(version: "a; rm -rf /")

    assert_response :unprocessable_entity
    assert_equal 0, @managed_app.deploy_events.count
  end
end
