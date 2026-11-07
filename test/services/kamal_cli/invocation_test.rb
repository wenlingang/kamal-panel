require "test_helper"

class KamalCli::InvocationTest < ExecutionLayerTest
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

  # Only change the variable name the registry password references to a non-default value -- this is
  # exactly what this new group of tests is meant to pin: an implementation that hard-codes
  # KAMAL_REGISTRY_PASSWORD goes red right here. The port follows BASE_YAML's, otherwise FakeHost
  # can't be reached.
  CUSTOM_REGISTRY_ENV_YAML = BASE_YAML.sub("KAMAL_REGISTRY_PASSWORD", "MY_OWN_REGISTRY_TOKEN")

  def build_app(**attrs)
    app_name = "blog-#{SecureRandom.hex(4)}"
    ManagedApp.create!(
      name: app_name,
      config_yaml: BASE_YAML,
      destination: "production",
      ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key,
                                      name: "#{app_name} 的 SSH 私钥"),
      **attrs
    )
  end

  # A hook that writes the fact of its own invocation to disk. It writes `env`: one dump can answer
  # three questions at once -- did the hook actually run, is `.kamal/secrets` actually reachable,
  # and which of the panel's environment variables the subprocess can actually see.
  def env_dumping_app(marker_path, hook: "pre-connect", **attrs)
    build_app(
      kamal_hooks: { hook => "#!/bin/sh\nenv > #{marker_path}\n" }.to_json,
      **attrs
    )
  end

  test "never writes the private key to disk" do
    app = build_app
    leaked = []
    before = snapshot_paths

    # File contents must be read inside run's block, before the tempdir is cleaned up -- after run
    # returns Dir.mktmpdir has already deleted the whole directory, and reading then only gets
    # ENOENT.
    #
    # The scan scope is deliberately wider than "the panel's own temp dir": the whole $TMPDIR tree
    # (including dotfiles) plus ~/.ssh. Watching only kamal-panel-*/**/* would miss a Tempfile
    # written to the $TMPDIR root, or a dotfile written as .ssh/id_ed25519 (Dir.glob's **/* doesn't
    # match dotfiles by default).
    scanned = false

    KamalCli::Invocation.new(app).run(%w[app details]) do |_line|
      next if scanned

      scanned = true

      (snapshot_paths - before).each do |path|
        content = begin
          next unless File.file?(path)
          next if File.size(path) > 2_000_000

          File.read(path)
        rescue StandardError
          nil
        end

        leaked << path if content&.include?("PRIVATE KEY")
      end
    end

    assert scanned, "the scan never ran, so this test has no detection power"
    assert_empty leaked, "no newly created file during the call may contain the private key content"
  end

  test "a timeout kills the whole process group and returns 124" do
    # The old test used `app logs --follow`, expecting it to "never exit on its own". It actually
    # does: the temp dir has no git repo, kamal can't compute version, and exits with 123 within a
    # few hundred milliseconds, and `refute_equal 0, status` passes for 123 too -- the timeout
    # branch never ran.
    #
    # This changes it to use a hook to cause a [real] hang: the hook first writes down its own pid,
    # then sleeps. It is kamal's grandchild process, so this test pins two things at once:
    #   1. the timeout branch really ran (124 + that message + a time upper bound);
    #   2. what gets killed is the whole process group, not just kamal itself -- without pgroup this
    #      sleep would keep living after the panel shows "terminated" (in a real scenario it's an ssh/docker
    #      acting on the user's production machine).
    Dir.mktmpdir("kamal-panel-hooktest-") do |probe|
      pidfile = File.join(probe, "hook.pid")
      app = build_app(kamal_hooks: {
        "pre-connect" => "#!/bin/sh\necho $$ > #{pidfile}\nsleep 300\n"
      }.to_json)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = KamalCli::Invocation.new(app, timeout: 3).run(%w[app details --version v1]) { |_| }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal KamalCli::Invocation::TIMEOUT_STATUS, result[:status]
      assert_includes result[:output], "执行超时，已终止"
      assert_operator elapsed, :<, 60, "a 3 second timeout should not drag the whole call past 60 seconds"

      hook_pid = File.read(pidfile).to_i
      assert_operator hook_pid, :>, 0, "the hook should really have run (otherwise this run never hung on the hook)"
      assert_raises(Errno::ESRCH, "kamal's grandchild process must also die with the timeout") do
        # Give the kernel a moment to reap
        20.times { Process.kill(0, hook_pid); sleep 0.1 }
      end
    end
  end

  test "the subprocess cannot see the panel's sensitive environment variables" do
    # kamal ERB-evaluates the user's deploy.yml, which means attacker-influenced code can run
    # in this subprocess. Open3's env argument is merged into ENV, and without
    # unsetenv_others it would get RAILS_MASTER_KEY -- a key that can decrypt every
    # Credential row (= every other app's private key).
    Dir.mktmpdir("kamal-panel-hooktest-") do |probe|
      marker = File.join(probe, "hook-ran")
      app = env_dumping_app(marker)

      with_env("RAILS_MASTER_KEY" => "panel-master-key-marker",
               "AR_ENCRYPTION_PRIMARY_KEY" => "panel-ar-key-marker") do
        KamalCli::Invocation.new(app).run(%w[app details --version v1]) { |_| }
      end

      dumped = File.read(marker)
      refute_includes dumped, "panel-master-key-marker", "RAILS_MASTER_KEY must not enter the subprocess"
      refute_includes dumped, "panel-ar-key-marker", "AR_ENCRYPTION_* must not enter the subprocess"
      assert_match(/^SSH_AUTH_SOCK=/, dumped, "what belongs on the allowlist must still be there")
      assert_match(/^PATH=/, dumped)
    end
  end

  private
    # Hand-written traversal instead of Dir.glob: $TMPDIR contains directories the current user
    # can't read, such as macOS's own TemporaryItems, and Dir.glob raises EPERM when it hits one,
    # turning the whole test into "an error from environment noise" rather than "checking for
    # leaks".
    def snapshot_paths
      found = []
      [ Dir.tmpdir, File.join(Dir.home, ".ssh") ].each { |root| walk_paths(root, found, 0) }
      found
    end

    def walk_paths(dir, acc, depth)
      return if depth > 8

      Dir.children(dir).each do |name|
        path = File.join(dir, name)
        acc << path
        walk_paths(path, acc, depth + 1) if File.directory?(path) && !File.symlink?(path)
      end
    rescue SystemCallError
      nil
    end

    def with_env(values)
      previous = values.keys.index_with { |key| ENV[key] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
end
