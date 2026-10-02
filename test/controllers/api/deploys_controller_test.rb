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

  test "认得的 token 收下上报，且不回任何内容" do
    post_report

    assert_response :no_content
    assert_equal "", response.body
    assert_equal 1, @managed_app.deploy_events.count
  end

  test "不认的 token 是 401，不落任何行" do
    post_report(token: "nope")

    assert_response :unauthorized
    assert_equal 0, DeployEvent.count
  end

  test "service 与 token 不匹配是 409，并记在应用上" do
    post_report(service: "other")

    assert_response :conflict
    assert_equal 0, @managed_app.deploy_events.count
    assert_match "other", @managed_app.reload.last_hook_rejection
  end

  test "destination 与 token 不匹配是 409" do
    post_report(destination: "staging")

    assert_response :conflict
    assert_match "staging", @managed_app.reload.last_hook_rejection
  end

  test "非法 version 是 422" do
    post_report(version: "a; rm -rf /")

    assert_response :unprocessable_entity
    assert_equal 0, @managed_app.deploy_events.count
  end

  test "未知 phase 是 422" do
    post_report(phase: "whatever")

    assert_response :unprocessable_entity
  end

  test "状态发生变化时触发 burst 轮询" do
    post_report(phase: "started")

    assert_equal PollCadence::BURST, PollCadence.interval_for(@managed_app)
  end

  test "重复上报不再撬动 burst" do
    post_report(phase: "started")
    Rails.cache.clear

    post_report(phase: "started")

    refute_equal PollCadence::BURST, PollCadence.interval_for(@managed_app),
                 "重复上报不该反复触发一次 SSH 扇出"
  end

  test "超出限流后返回 429，且不回任何内容" do
    31.times { post_report }

    assert_response :too_many_requests
    assert_equal "", response.body
  end

  test "config_yaml 解析不过时是 409，文案指向配置而不是 token" do
    @managed_app.update_column(:config_yaml, "not: [valid, yaml: broken")
    assert_not @managed_app.reload.valid?

    post_report

    assert_response :conflict
    assert_equal 0, @managed_app.deploy_events.count
    rejection = @managed_app.reload.last_hook_rejection
    assert_match "解析", rejection
    assert_no_match "粘到了别的项目", rejection
  end

  test "performer 与 command 过长时截断而不是报错" do
    post_report(performer: "x" * 500, command: "y" * 500)

    assert_response :no_content
    assert_operator @managed_app.deploy_events.sole.performer.length, :<=, 255
  end
end
