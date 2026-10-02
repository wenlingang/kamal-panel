require "test_helper"

class RunActionJobTest < ExecutionLayerTest
  include ActiveJob::TestHelper

  BASE_YAML = <<~YAML
    service: blog
    image: example/blog
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

  def build_app(**attrs)
    app_name = "blog-#{SecureRandom.hex(4)}"
    ManagedApp.create!(
      name: app_name, config_yaml: BASE_YAML, destination: "production",
      ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key,
                                      name: "#{app_name} 的 SSH 私钥"),
      **attrs
    )
  end

  def build_user = User.create!(email_address: "op-#{SecureRandom.hex(4)}@example.com",
                                password: "secret123456", role: "admin")

  def start_log(app, action_name, target_version: nil)
    AuditLog.start!(user: build_user, managed_app: app, action_name: action_name,
                    target_version: target_version, hosts: [ "127.0.0.1" ])
  end

  test "锁状态未知时阻塞动作——不当成「未锁定」处理（task-5 教训）" do
    app = build_app
    app.update_column(:config_yaml, app.config_yaml.sub("127.0.0.1", "192.0.2.1"))
    app.reload

    log = start_log(app, "stop")

    assert_no_enqueued_jobs(only: PollManagedAppJob) do
      RunActionJob.new.perform(log.id)
    end

    log.reload
    assert_equal "failure", log.result
    assert_match "锁状态未知", log.output_digest
  end

  test "已加锁时阻塞动作，不执行命令" do
    app = build_app
    lock_dir = ".kamal/lock-blog-production"
    FakeHost.ssh("node-1", "mkdir -p #{lock_dir} && printf 'Locked by: ci@example.com' | base64 > #{lock_dir}/details")

    log = start_log(app, "stop")

    begin
      assert_no_enqueued_jobs(only: PollManagedAppJob) do
        RunActionJob.new.perform(log.id)
      end

      log.reload
      assert_equal "failure", log.result
      assert_match "部署进行中", log.output_digest
      assert_match "ci@example.com", log.output_digest
    ensure
      FakeHost.ssh("node-1", "rm -rf #{lock_dir}")
    end
  end

  test "无锁时真正执行动作，成功后触发 burst 轮询并让新的 Observation 确认" do
    container = FakeHost.seed_container(
      node: "node-1", service: "blog", role: "web", destination: "production", version: "v1"
    )

    app = build_app
    log = start_log(app, "stop")

    assert_enqueued_with(job: PollManagedAppJob, args: [ app ]) do
      RunActionJob.new.perform(log.id)
    end

    log.reload
    assert_equal "success", log.result
    assert_match(/\Akamal app stop --version /, log.command)
    assert_equal PollCadence::BURST, PollCadence.interval_for(app)

    assert_equal "exited", FakeHost.ssh("node-1", "docker inspect -f '{{.State.Status}}' #{container}").strip
  end

  test "未知动作名不会走到这里（注册表在 Actions::Base 层已经拒绝）——job 假设 action_name 已合法" do
    app = build_app
    log = AuditLog.create!(user: build_user, managed_app: app, action_name: "exec",
                           target_version: nil, hosts: [], result: "pending")

    assert_raises(Actions::Base::UnknownAction) { RunActionJob.new.perform(log.id) }
  end

  # 这一条存在的原因很具体：broadcast_result 里那个 rescue StandardError 是为了
  # 「投递失败不连累执行本身」，但它顺带会吞掉【文案本身出错】——比如少写一条
  # 译文。那种 bug 的表现是页面永远停在"执行中……"，离原因非常远，而且只有跑
  # 系统测试才看得见。这里用最便宜的方式把那一类挡在前面。
  test "终态广播用到的译文中英文都存在" do
    %w[actions.result.succeeded actions.result.failed].each do |key|
      %i[zh-CN en].each do |locale|
        assert I18n.exists?(key, locale), "#{key} 缺 #{locale} 译文"
      end
    end
  end

  test "终态广播按发起人的语言渲染" do
    app = ManagedApp.create!(name: "broadcast-locale", config_yaml: BASE_YAML,
                             destination: "production")
    log = AuditLog.start!(user: users(:two), managed_app: app, action_name: "restart",
                          target_version: "abc1234", hosts: [ "127.0.0.1" ])
    users(:two).update!(locale: "en")
    log.finish!(result: "success", command: "x", output_digest: "", duration_ms: 1)

    assert_equal "Done — the panel is collecting again to confirm",
                 RunActionJob.new.send(:result_text, log.reload)
  end

  test "发起人没设语言时终态广播用默认语言" do
    app = ManagedApp.create!(name: "broadcast-default", config_yaml: BASE_YAML,
                             destination: "production")
    log = AuditLog.start!(user: users(:two), managed_app: app, action_name: "restart",
                          target_version: "abc1234", hosts: [ "127.0.0.1" ])
    users(:two).update!(locale: nil)
    log.finish!(result: "failure", command: "x", output_digest: "", duration_ms: 1)

    assert_equal "失败", RunActionJob.new.send(:result_text, log.reload)
  end
end
