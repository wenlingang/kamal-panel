require "application_system_test_case"

# 计划 02 Task 12 Step 4 的自我验收，落成可重复执行的测试而不是一次性的
# 手工点击：接一个真实指向 fake host 的应用 → 真实采集 → 看回滚候选 →
# 在界面上发起一次 stop → 确认执行页有输出、审计不停在 pending。
class AcceptanceTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    FakeHost.ensure_ready!
    FakeHost.reset_all!

    yaml = <<~YAML
      service: blog
      image: busybox:latest
      servers:
        web:
          - 127.0.0.1
      registry:
        server: registry.example.com
        username: someone
        password:
          - KAMAL_REGISTRY_PASSWORD
      builder:
        arch: amd64
      ssh:
        user: deploy
        port: #{FakeHost::NODES.fetch("node-1")}
    YAML

    @app = ManagedApp.create!(name: "blog", config_yaml: yaml, destination: "production",
                              ssh_credential: Credential.new(kind: "ssh_key",
                                                             value: FakeHost.private_key,
                                                             name: "blog 的 SSH 私钥"))
  end

  test "admin 能看到真实采集结果、正确的回滚候选，并在界面上发起一次真实的 stop" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "oldold1", state: :stopped)
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "newnew2")
    PollManagedAppJob.perform_now(@app)

    # 采集到的确实是 fake host 上真实存在的两个容器
    versions = Observation.latest_for(@app).filter_map(&:version)
    assert_includes versions, "oldold1"
    assert_includes versions, "newnew2"

    # 只有停着的那个版本进候选，正在跑的那个不进
    candidates = RollbackCandidates.new(@app).list
    assert_equal [ "oldold1" ], candidates.map { |c| c[:version] }
    assert candidates.first[:available], candidates.first[:reason]

    sign_in_as(User.create!(email_address: "op@example.com", password: "secret123456",
                            role: "admin"))
    visit managed_app_path(@app)

    assert_text "oldold1"
    assert_selector "input[type=radio][value='oldold1']:not([disabled])"

    # 界面上发起一次 stop——这三个按钮曾经是 type="button" 的死按钮
    find("details.stop-app summary", text: "停止").click
    fill_in "stop_confirm_name", with: "blog"
    click_on "确认停止"
    # 动作输出页的标题走 audit_action_label，显示的是译名而不是 action_name
    # 那个原始键——同一个动作在审计页上早就是中文，这一页此前还印着 "stop"。
    assert_text "停止 —— blog"

    # 系统测试里 perform_later 只是入队（:test 适配器）。这里要的是"点下
    # 按钮之后真的会有一次执行"，所以把排到的那个 job 真跑一遍。
    perform_enqueued_jobs

    log = AuditLog.order(:created_at).last
    assert_equal "stop", log.action_name
    refute_equal "pending", log.result, "执行完必须更新审计"
    assert_match "127.0.0.1", log.output_digest.to_s
    assert_text log.result == "success" ? "已完成" : "失败"
  end
end
