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

  test "rejects a service/token mismatch with 409 and records it on the app" do
    post_report(service: "other")

    assert_response :conflict
    assert_equal 0, @managed_app.deploy_events.count
    assert_match "other", @managed_app.reload.last_hook_rejection
  end

  test "rejects a destination/token mismatch with 409" do
    post_report(destination: "staging")

    assert_response :conflict
    assert_match "staging", @managed_app.reload.last_hook_rejection
  end

  test "rejects an invalid version with 422" do
    post_report(version: "a; rm -rf /")

    assert_response :unprocessable_entity
    assert_equal 0, @managed_app.deploy_events.count
  end

  test "rejects an unknown phase with 422" do
    post_report(phase: "whatever")

    assert_response :unprocessable_entity
  end

  test "triggers burst polling when the state changes" do
    post_report(phase: "started")

    assert_equal PollCadence::BURST, PollCadence.interval_for(@managed_app)
  end

  test "does not trigger burst again on a repeated report" do
    post_report(phase: "started")
    Rails.cache.clear

    post_report(phase: "started")

    refute_equal PollCadence::BURST, PollCadence.interval_for(@managed_app),
                 "a repeated report must not trigger an SSH fan-out each time"
  end

  test "returns 429 with no content once the rate limit is exceeded" do
    31.times { post_report }

    assert_response :too_many_requests
    assert_equal "", response.body
  end

  test "rejects with 409 when config_yaml cannot be parsed, and the message points at the config rather than the token" do
    @managed_app.update_column(:config_yaml, "not: [valid, yaml: broken")
    assert_not @managed_app.reload.valid?

    post_report

    assert_response :conflict
    assert_equal 0, @managed_app.deploy_events.count
    rejection = @managed_app.reload.last_hook_rejection
    assert_match "解析", rejection
    assert_no_match "粘到了别的项目", rejection
  end

  test "truncates an overlong performer and command instead of raising" do
    post_report(performer: "x" * 500, command: "y" * 500)

    assert_response :no_content
    assert_operator @managed_app.deploy_events.sole.performer.length, :<=, 255
  end
end
