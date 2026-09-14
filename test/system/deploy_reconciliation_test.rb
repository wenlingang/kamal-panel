require "application_system_test_case"

# 主设计 9.4 的第三个场景：POST 一个 DeployEvent 但不实际启动容器，
# 超时后必须出现矛盾告警；容器真的起来之后告警必须自动消失、痕迹必须留下。
class DeployReconciliationTest < ApplicationSystemTestCase
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

    @managed_app = ManagedApp.create!(name: "blog", config_yaml: yaml, destination: "production",
                              ssh_credential: Credential.new(kind: "ssh_key",
                                                             value: FakeHost.private_key,
                                                             name: "blog 的 SSH 私钥"))
    sign_in_as(User.create!(email_address: "v@example.com", password: "secret123456",
                            role: "ops"))
  end

  test "上报了但机器上没有，超时后告警；容器起来后告警消失且留下延迟" do
    event = DeployEvent.create!(managed_app: @managed_app, version: "aaaaaaa", source: "hook",
                                succeeded_at: Time.current)

    PollManagedAppJob.perform_now(@managed_app)   # 真实采集：此刻什么容器都没有
    assert_nil event.reload.observed_at

    travel DeployEvent::UNOBSERVED_AFTER + 1.second do
      visit managed_app_path(@managed_app)
      assert_text "未在任何机器上观测到"
    end

    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")
    PollManagedAppJob.perform_now(@managed_app)

    assert_predicate event.reload.observed_at, :present?

    visit managed_app_path(@managed_app)
    assert_no_text "未在任何机器上观测到"
    assert_text "延迟"
  end
end
