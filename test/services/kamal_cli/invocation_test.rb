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

  test "runs a read-only kamal command against a real host, authenticating only via ssh-agent" do
    # The load-bearing assertion of this test isn't "there is output" but "the output has that
    # container name that can only be seen via SSH + docker".
    #
    # Without this assertion, an [authentication failure] would also let the test pass: without an
    # agent `kamal app details` prints "deploy@127.0.0.1's password:" plus an
    # SSHKit::Runner::ExecuteError, which is still "some lines of output + an Integer exit code".
    # And "authenticating with only the agent, nothing on disk, and no ssh -i" is the load-bearing
    # premise of the whole plan, so it must have a test that goes red when it doesn't hold.
    container = FakeHost.seed_container(
      node: "node-1", service: "blog", role: "web", destination: "production", version: "v1"
    )

    lines = []
    result = KamalCli::Invocation.new(build_app).run(%w[app details]) { |line| lines << line }

    assert_kind_of Integer, result[:status]
    assert_predicate lines, :any?, "should produce output line by line"
    assert_includes result[:output], container,
                    "the remote container name should appear in the output, otherwise the host was never actually reached (e.g. auth failed)"
    refute_match(/password:|Authentication failed|Permission denied/, result[:output],
                 "no sign of an authentication failure should appear in the output")
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

  test "cleans up the temp directory and agent after the call" do
    app = build_app
    before = Dir.glob("#{Dir.tmpdir}/#{KamalCli::Invocation::TMPDIR_PREFIX}*").size

    invocation = KamalCli::Invocation.new(app)
    invocation.run(%w[version]) { |_| }

    assert_equal before, Dir.glob("#{Dir.tmpdir}/#{KamalCli::Invocation::TMPDIR_PREFIX}*").size

    # An unchanged directory count can't prove the agent is dead -- "no key in the filesystem, but
    # the decrypted key is still reachable through a socket" is exactly the worst leak shape here,
    # and it has nothing to do with the directory count.
    agent = invocation.agent
    assert_not_nil agent&.pid
    assert_raises(Errno::ESRCH, "ssh-agent should have exited") { Process.kill(0, agent.pid.to_i) }
    assert_not File.exist?(agent.auth_sock), "the agent's socket should be gone"
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

  test "kamal actually loads the deploy.<destination>.yml override file" do
    # This project has already fixed "connected to the wrong machine" twice, and a filename typo in
    # write_project_files (deploy-production.yml) produces no error at all: kamal loads only the
    # base config and acts on the [wrong host] as usual, with all four old tests green. So here the
    # host in the override file is an address that isn't in the base config at all, and then we ask
    # which hosts kamal itself computes. `kamal config` runs only locally (main.rb:127-132) and
    # doesn't connect to hosts.
    app = build_app(destination_config_yaml: <<~YAML)
      servers:
        web:
          - 10.77.77.77
    YAML

    # The temp dir has no git repo (the panel never touches source code), so commands that need a
    # version must pass --version explicitly, otherwise kamal reports "no git repository found".
    result = KamalCli::Invocation.new(app).run(%w[config --version v1]) { |_| }

    assert_equal 0, result[:status], result[:output]
    assert_includes result[:output], "10.77.77.77", "the host from the destination override file should be used"
    refute_includes result[:output], "127.0.0.1", "the override file should replace the host in the base config"
  end

  test "the user's own pre/post-deploy hooks actually fire" do
    # The entire reason for "calling the CLI rather than assembling commands ourselves" is to let
    # users' hooks fire as usual. Before this test existed, that sentence was just an assertion in
    # the header comment of invocation.rb, and the implementation (chdir into an empty directory)
    # made it necessarily false.
    Dir.mktmpdir("kamal-panel-hooktest-") do |probe|
      marker = File.join(probe, "hook-ran")
      app = env_dumping_app(marker)

      # Once there is a hook, kamal must compute config.version (the KAMAL_VERSION tag),
      # and the temp dir has no git repo -- so commands with hooks must pass --version explicitly.
      result = KamalCli::Invocation.new(app).run(%w[app details --version v1]) { |_| }

      assert File.exist?(marker), "the pre-connect hook should have run. kamal output:\n#{result[:output]}"
      assert_match(/^KAMAL_SERVICE=blog$/, File.read(marker),
                   "the hook should run inside the hook environment provided by kamal, not be hit by something else by chance")
    end
  end

  test "kamal can read .kamal/secrets, and the array-style password syntax works" do
    # `registry.password: [KAMAL_REGISTRY_PASSWORD]` is Kamal 2's standard form, and also the form
    # this fixture uses. When the secrets file is unreachable it raises ConfigurationError directly
    # in app boot / rollback (Task 7's target). The cheapest path for kamal to parse the secrets
    # file itself is run_hook(secrets: true): it merges config.secrets.to_h into the hook's
    # environment.
    Dir.mktmpdir("kamal-panel-hooktest-") do |probe|
      marker = File.join(probe, "hook-ran")
      app = env_dumping_app(marker, kamal_secrets: "KAMAL_REGISTRY_PASSWORD=s3cr3t-from-panel\n")

      KamalCli::Invocation.new(app).run(%w[app details --version v1]) { |_| }

      assert_match(/^KAMAL_REGISTRY_PASSWORD=s3cr3t-from-panel$/, File.read(marker),
                   "kamal should read this secret from the .kamal/secrets-common written by the panel")
    end
  end

  # The variable name comes from the app's own deploy.yml (the name in CUSTOM_REGISTRY_ENV_YAML
  # isn't KAMAL_REGISTRY_PASSWORD -- an implementation with a hard-coded constant goes red right
  # here).
  test "writes the password into secrets-common under the variable name the config references when a registry credential is selected" do
    Dir.mktmpdir("kamal-panel-hooktest-") do |probe|
      marker = File.join(probe, "hook-ran")
      secret = "s3cr3t-#{SecureRandom.hex(4)}"
      app = env_dumping_app(marker, config_yaml: CUSTOM_REGISTRY_ENV_YAML)
      app.update!(registry_credential: RegistryCredential.create!(name: "Docker Hub", value: secret))

      KamalCli::Invocation.new(app).run(%w[app details --version v1]) { |_| }

      assert_match(/^MY_OWN_REGISTRY_TOKEN=#{Regexp.escape(secret)}$/, File.read(marker),
                   "kamal should read the password written under the config's variable name from the .kamal/secrets-common written by the panel")
    end
  end

  # The env-dump marker file can't catch this: when kamal merges secrets into the hook environment,
  # whether a line ends with an extra "\n" doesn't affect the output of the `env` command. What's
  # verified here is the bytes of the file the panel writes out, so we call write_project_files
  # directly -- it doesn't connect to hosts and needs no kamal, and can read the raw content of
  # .kamal/secrets-common directly.
  #
  # kamal_secrets deliberately has no trailing newline: the old implementation was `File.write(...,
  # kamal_secrets)` writing it out verbatim; if the new implementation also adds a separator newline
  # when there's only the free-text part, this would go red -- which is exactly the check point of
  # the promise "apps that didn't pick a registry credential are unaffected byte for byte".
  test "writes kamal_secrets without a trailing newline verbatim, not one byte extra, when no registry credential is selected" do
    Dir.mktmpdir("kamal-panel-writetest-") do |dir|
      app = build_app(kamal_secrets: "RAILS_MASTER_KEY=abc")

      KamalCli::Invocation.new(app).send(:write_project_files, dir)

      assert_equal "RAILS_MASTER_KEY=abc", File.read(File.join(dir, ".kamal", "secrets-common")),
                   "for an app with no registry credential selected, the written secrets-common should be byte-identical to before"
    end
  end

  test "writes both when both contents are present" do
    Dir.mktmpdir("kamal-panel-hooktest-") do |probe|
      marker = File.join(probe, "hook-ran")
      app = env_dumping_app(marker, config_yaml: CUSTOM_REGISTRY_ENV_YAML, kamal_secrets: "RAILS_MASTER_KEY=abc\n")
      app.update!(registry_credential: RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t"))

      KamalCli::Invocation.new(app).run(%w[app details --version v1]) { |_| }

      dumped = File.read(marker)
      assert_match(/^RAILS_MASTER_KEY=abc$/, dumped)
      assert_match(/^MY_OWN_REGISTRY_TOKEN=s3cr3t$/, dumped)
    end
  end

  # This one goes through the whole chain (panel writes the file -> kamal parses with dotenv -> hook
  # environment), because what needs pinning isn't "which bytes the panel wrote" but "whether what
  # dotenv finally hands kamal is the original password". Without quotes dotenv would truncate at #,
  # strip trailing whitespace, unescape \s into s, interpolate $HOME away, and [actually execute]
  # $(id) -- and that executes on the panel's machine, not on the target host.
  test "dotenv metacharacters in the password reach kamal verbatim and $(...) is not executed as a command" do
    Dir.mktmpdir("kamal-panel-hooktest-") do |probe|
      marker = File.join(probe, "hook-ran")
      secret = "p@ss#word $(id) $HOME back\\slash "
      app = env_dumping_app(marker, config_yaml: CUSTOM_REGISTRY_ENV_YAML)
      app.update!(registry_credential: RegistryCredential.create!(name: "Docker Hub", value: secret))

      KamalCli::Invocation.new(app).run(%w[app details --version v1]) { |_| }

      dumped = File.read(marker)
      assert_match(/^MY_OWN_REGISTRY_TOKEN=#{Regexp.escape(secret)}$/, dumped,
                   "the password should arrive at kamal byte for byte: no truncation, unescaping, interpolation, or command substitution")
      refute_match(/^MY_OWN_REGISTRY_TOKEN=.*uid=\d+/, dumped,
                   "$(id) must never be executed on the panel machine")
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

  test "re-raises exceptions from the caller's block as-is instead of swallowing them into a timeout" do
    app = build_app
    boom = Class.new(StandardError)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    error = assert_raises(boom) do
      KamalCli::Invocation.new(app, timeout: 120).run(%w[app details]) { |_line| raise boom, "行处理器炸了" }
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal "行处理器炸了", error.message
    # The original implementation let this exception kill the reader thread, the pipe was no longer
    # drained, kamal hung, and it finally ran out the whole timeout and returned status 124 -- a bug
    # in Task 7's line handler would be reported to ops as "kamal hung".
    assert_operator elapsed, :<, 60, "an error in the call block should terminate the subprocess immediately instead of waiting out the timeout"
  end

  test "a subprocess killed by a signal also returns an Integer exit code" do
    # exitstatus is nil for a signal-killed child, and returning it directly would break the
    # documented `status: Integer` contract (a caller's single result[:status].zero? is a
    # NoMethodError). Converted to 128 + signo, following shell convention.
    pid = Process.spawn("sleep", "30", out: File::NULL, err: File::NULL)
    Process.kill("KILL", pid)
    _, process_status = Process.wait2(pid)

    assert_nil process_status.exitstatus
    assert_equal 128 + Signal.list.fetch("KILL"),
                 KamalCli::Invocation.new(build_app).send(:exit_status, process_status)
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
