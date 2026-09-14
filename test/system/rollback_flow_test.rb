require "application_system_test_case"

class RollbackFlowTest < ApplicationSystemTestCase
  setup do
    @app = ManagedApp.create!(name: "blog",
                              config_yaml: file_fixture("two_host_deploy.yml").read,
                              destination: "production")
    sign_in_as(User.create!(email_address: "op@example.com", password: "secret123456",
                            role: "admin"))
  end

  # 和 role_visibility_test 同样的理由：这个文件测的是"哪些版本可选"，
  # 不是 KamalLock 真实读锁。fixture 里的 10.0.0.1 并不存在，不 stub 的话
  # 整个操作区都会因为"锁状态未知"而不渲染，失败原因与回滚无关。
  def visit_show_as_unlocked
    original_status = KamalLock.instance_method(:status)
    KamalLock.define_method(:status) { { locked: false, details: nil, error: nil } }
    yield
  ensure
    KamalLock.define_method(:status, original_status)
  end

  def observe(host:, version:, status: "exited")
    Observation.create!(managed_app: @app, host: host, role: "web",
                        container_name: "blog-web-production-#{version}",
                        version: version, docker_status: status,
                        reachable: true, observed_at: Time.current)
  end

  test "缺容器的版本被置灰并注明原因" do
    observe(host: "10.0.0.1", version: "aaaaaaa")

    visit_show_as_unlocked { visit managed_app_path(@app) }

    assert_text "10.0.0.2 上已被清理"
    assert_selector "input[type=radio][value='aaaaaaa'][disabled]"
  end

  test "每台主机都有的版本可以选中并提交" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", version: "aaaaaaa")

    visit_show_as_unlocked { visit managed_app_path(@app) }

    assert_selector "input[type=radio][value='aaaaaaa']:not([disabled])"
    choose "aaaaaaa"
    fill_in "rollback_confirm_name", with: "blog"
    click_on "执行回滚"

    # 等页面真的跳到动作详情页再查库——否则 click_on 一返回就查，
    # 请求可能还没落库（第一次跑就这样红过一次）。
    assert_text "回滚 —— blog"

    log = AuditLog.order(:created_at).last
    assert_equal "rollback", log.action_name
    assert_equal "aaaaaaa", log.target_version
  end
end
