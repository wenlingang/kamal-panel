require "application_system_test_case"

class DeployHistoryTest < ApplicationSystemTestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    sign_in_as(User.create!(email_address: "v@example.com", password: "secret123456",
                            role: "ops"))
  end

  # 简报原用例让一个没生成过 token 的应用断言页面出现 curl -v——但那句
  # 只在 hook_reporting_enabled? 为真的分支里，照抄必然红。按裁决拆成两条：
  # 没配上报时给的是「去生成 token」的引导，不是排查命令。
  test "没配上报时给的是生成 token 的引导，不是一个空表格" do
    visit managed_app_path(@app)

    assert_text "还没有部署记录"
    assert_text "生成 token"
    assert_no_text "curl -v"
  end

  test "已配上报但还没收到时给的是排查路径" do
    @app.regenerate_hook_token!

    visit managed_app_path(@app)

    assert_text "还没有部署记录"
    assert_text "curl -v"
    assert_text "chmod +x"
  end

  test "有事件时列出版本、发起人与观测延迟" do
    DeployEvent.create!(managed_app: @app, version: "aaaaaaa", source: "hook",
                        performer: "ci-bot", command: "deploy",
                        started_at: 12.minutes.ago, succeeded_at: 10.minutes.ago,
                        observed_at: 10.minutes.ago + 77.seconds)

    visit managed_app_path(@app)

    assert_text "aaaaaaa"
    assert_text "ci-bot"
    # 延迟必须显示出来：这就是"曾经延迟过"的痕迹
    assert_text "77 秒"
  end

  # Kamal 的真实时序是「容器先 running → 健康检查 → 切流量 → post-deploy
  # hook 才上报成功」——面板轮询只要看到 running 就回填 observed_at，
  # 所以 observed_at 常态性地早于 succeeded_at，"延迟"这个说法在这种
  # 情况下是错的（负数被夹成 0 会把这条信息抹掉），要换一种说法。
  test "上报前已观测到时不说延迟" do
    DeployEvent.create!(managed_app: @app, version: "ccccccc", source: "hook",
                        started_at: 12.minutes.ago, succeeded_at: 9.minutes.ago,
                        observed_at: 10.minutes.ago)

    visit managed_app_path(@app)

    assert_text "上报前已观测到"
    assert_no_text "延迟"
  end

  test "尚未观测到的那行如实说未验证" do
    DeployEvent.create!(managed_app: @app, version: "bbbbbbb", source: "hook",
                        succeeded_at: 2.minutes.ago)

    visit managed_app_path(@app)

    assert_text "未验证"
  end

  test "两种来源的行各自显示正确的文字" do
    at = 5.minutes.ago
    DeployEvent.create!(managed_app: @app, version: "aaaaaaa", source: "hook",
                        performer: "ci-bot", command: "deploy",
                        succeeded_at: at, observed_at: at + 30.seconds)
    DeployEvent.create!(managed_app: @app, version: "bbbbbbb", source: "inferred",
                        succeeded_at: at, observed_at: at)

    visit managed_app_path(@app)

    assert_text "hook 上报"
    assert_text "面板推断"
    assert_text "面板观测到"

    within find("tr", text: "bbbbbbb") do
      assert_selector "td", text: "—", count: 2
    end
  end
end
