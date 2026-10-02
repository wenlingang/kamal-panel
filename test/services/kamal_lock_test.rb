require "test_helper"

class KamalLockTest < ExecutionLayerTest
  def build_app
    yaml = <<~YAML
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

    app_name = "blog-#{SecureRandom.hex(4)}"
    ManagedApp.create!(name: app_name, config_yaml: yaml,
                       destination: "production",
                       ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key,
                                                       name: "#{app_name} 的 SSH 私钥"))
  end

  test "reports unlocked when there is no lock" do
    status = KamalLock.new(build_app).status

    refute status[:locked]
    assert_nil status[:error]
  end

  test "reports locked with holder info when the lock directory exists" do
    app = build_app
    lock_dir = ".kamal/lock-blog-production"
    FakeHost.ssh("node-1", "mkdir -p #{lock_dir} && printf 'Locked by: ci@example.com' | base64 > #{lock_dir}/details")

    status = KamalLock.new(app).status

    assert status[:locked]
    assert_match "ci@example.com", status[:details]
  ensure
    FakeHost.ssh("node-1", "rm -rf .kamal/lock-blog-production")
  end

  test "still reports locked when the lock message contains the sentinel string (Critical 1, task-5 review)" do
    # A lock's details are free text written by whoever holds the lock (the message argument in
    # write_lock_details, coming from `kamal lock acquire -m`), and the panel has no control over
    # its content. The old implementation used `stdout.include?("LOCK_ABSENT")` to decide "is it
    # unlocked", yet that substring may well appear in this free text -- as soon as a lock message
    # mentions the characters "LOCK_ABSENT" (even just when discussing the sentinel itself), the old
    # implementation would misjudge "locked" as "unlocked". This test uses details that really
    # contain that substring but are still in the "locked" state, locking in that the new
    # implementation (which looks only at the first line's verdict marker, not the payload content)
    # won't repeat the mistake.
    app = build_app
    lock_dir = ".kamal/lock-blog-production"
    message = "Locked by: ci@example.com — investigating why LOCK_ABSENT never showed up in the logs"
    FakeHost.ssh("node-1", "mkdir -p #{lock_dir} && printf #{Shellwords.escape(message)} | base64 > #{lock_dir}/details")

    status = KamalLock.new(app).status

    assert status[:locked],
      "a lock message containing the substring \"LOCK_ABSENT\" must not be misread as \"unlocked\" -- the signal must not share a channel with free text"
    assert_match "ci@example.com", status[:details]
  ensure
    FakeHost.ssh("node-1", "rm -rf .kamal/lock-blog-production")
  end

  test "reports an error instead of 'unlocked' when the host is unreachable" do
    app = build_app
    app.update_column(:config_yaml, app.config_yaml.sub("127.0.0.1", "192.0.2.1"))

    status = KamalLock.new(app.reload).status

    refute status[:locked]
    assert_predicate status[:error], :present?
  end
end
