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

  test "blocks the action when the lock state is unknown instead of treating it as unlocked (task-5 lesson)" do
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

  # An exception mid-run used to leave the audit row "pending" forever, and the action page saying
  # "running" forever. Whatever goes wrong, the row must end in a terminal state that says why.
  test "an error during execution finishes the audit row as a failure with the reason" do
    app = build_app(ssh_credential: nil)
    log = start_log(app, "logs")

    RunActionJob.new.perform(log.id)

    log.reload
    assert_equal "failure", log.result
    assert_match "SSH", log.output_digest
    assert_not_nil log.finished_at
  end

  test "blocks the action without running the command when locked" do
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

  test "runs the action when unlocked, then triggers burst polling and lets a new Observation confirm on success" do
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
    assert_equal PollCadence.burst, PollCadence.interval_for(app)

    assert_equal "exited", FakeHost.ssh("node-1", "docker inspect -f '{{.State.Status}}' #{container}").strip
  end
end
