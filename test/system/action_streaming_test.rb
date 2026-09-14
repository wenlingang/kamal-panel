require "application_system_test_case"

# spec 8.4 第 4 步是硬要求：不能是一个转圈动画然后告知"成功了"。
# 出问题时人需要看到卡在哪一步。
class ActionStreamingTest < ApplicationSystemTestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    @user = User.create!(email_address: "op@example.com", password: "secret123456",
                         role: "admin")
    sign_in_as(@user)
  end

  def start_log
    AuditLog.start!(user: @user, managed_app: @app, action_name: "restart",
                    target_version: nil, hosts: [ "10.0.0.1" ])
  end

  test "执行页订阅流并把新行实时追加进来" do
    log = start_log
    visit managed_app_action_path(@app, log)

    assert_selector "#action-output"
    assert_text "执行中"
    # 订阅是否真的建立了——只断言容器存在的话，把 turbo_stream_from 删掉也能过
    assert_selector "turbo-cable-stream-source", visible: :all

    Turbo::StreamsChannel.broadcast_append_to(
      "action_#{log.id}", target: "action-output",
      html: ActionController::Base.helpers.tag.div("Running docker ps on 10.0.0.1",
                                                   class: "output-line")
    )

    assert_text "Running docker ps on 10.0.0.1"
  end

  test "终态广播把执行中替换成结论" do
    log = start_log
    visit managed_app_action_path(@app, log)
    assert_text "执行中"

    log.finish!(result: "success", command: "kamal app boot", output_digest: "done",
                duration_ms: 12)
    Turbo::StreamsChannel.broadcast_replace_to(
      "action_#{log.id}", target: "action-result",
      html: ActionController::Base.helpers.tag.strong("已完成 —— 面板正在重新采集确认")
    )

    assert_text "已完成"
    assert_no_text "执行中"
  end

  test "执行结束后才打开这一页也能看到已落库的输出" do
    log = start_log
    log.finish!(result: "failure", command: "kamal app boot",
                output_digest: "INFO Running docker ps\nERROR 卡在这一步", duration_ms: 34)

    visit managed_app_action_path(@app, log)

    assert_text "INFO Running docker ps"
    assert_text "ERROR 卡在这一步"
    assert_text "失败"
  end
end
