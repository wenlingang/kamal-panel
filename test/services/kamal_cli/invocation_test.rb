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

  test "能对真实主机跑通一条只读的 kamal 命令——且认证确实只靠 ssh-agent" do
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
    assert_predicate lines, :any?, "应逐行产出输出"
    assert_includes result[:output], container,
                    "输出里应出现远端容器名——否则说明这次并没有真的连上主机（例如认证失败）"
    refute_match(/password:|Authentication failed|Permission denied/, result[:output],
                 "输出里不得出现认证失败的痕迹")
  end

  test "私钥全程不落盘" do
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

    assert scanned, "扫描一次都没跑到——这条测试就没有检测力了"
    assert_empty leaked, "调用期间新出现的文件中不得包含私钥内容"
  end

  test "调用结束后临时目录与 agent 均被清理" do
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
    assert_raises(Errno::ESRCH, "ssh-agent 应已退出") { Process.kill(0, agent.pid.to_i) }
    assert_not File.exist?(agent.auth_sock), "agent 的 socket 应已消失"
  end

  test "超时会杀掉整个进程组并返回 124" do
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
      assert_operator elapsed, :<, 60, "3 秒的超时不应把整条调用拖过 60 秒"

      hook_pid = File.read(pidfile).to_i
      assert_operator hook_pid, :>, 0, "hook 应该真的跑起来过（否则这次并没有挂在 hook 上）"
      assert_raises(Errno::ESRCH, "kamal 的孙子进程也必须随超时一起死掉") do
        # Give the kernel a moment to reap
        20.times { Process.kill(0, hook_pid); sleep 0.1 }
      end
    end
  end

  test "kamal 真的加载了 deploy.<destination>.yml 覆盖文件" do
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
    assert_includes result[:output], "10.77.77.77", "应使用 destination 覆盖文件里的主机"
    refute_includes result[:output], "127.0.0.1", "覆盖文件应替换掉基础配置里的主机"
  end

  test "用户自己的 pre/post-deploy hook 确实会被触发" do
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

      assert File.exist?(marker), "pre-connect hook 应被执行。kamal 输出：\n#{result[:output]}"
      assert_match(/^KAMAL_SERVICE=blog$/, File.read(marker),
                   "hook 应在 kamal 提供的 hook 环境里执行，而不是被别的东西碰巧跑了一下")
    end
  end

  test "kamal 能读到 .kamal/secrets——数组式密码写法可用" do
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
                   "kamal 应从面板写出的 .kamal/secrets-common 里读到这个 secret")
    end
  end

  # The variable name comes from the app's own deploy.yml (the name in CUSTOM_REGISTRY_ENV_YAML
  # isn't KAMAL_REGISTRY_PASSWORD -- an implementation with a hard-coded constant goes red right
  # here).
  test "选了 registry 凭据时，密码按配置引用的变量名写进 secrets-common" do
    Dir.mktmpdir("kamal-panel-hooktest-") do |probe|
      marker = File.join(probe, "hook-ran")
      secret = "s3cr3t-#{SecureRandom.hex(4)}"
      app = env_dumping_app(marker, config_yaml: CUSTOM_REGISTRY_ENV_YAML)
      app.update!(registry_credential: RegistryCredential.create!(name: "Docker Hub", value: secret))

      KamalCli::Invocation.new(app).run(%w[app details --version v1]) { |_| }

      assert_match(/^MY_OWN_REGISTRY_TOKEN=#{Regexp.escape(secret)}$/, File.read(marker),
                   "kamal 应从面板写出的 .kamal/secrets-common 里读到按配置变量名写入的密码")
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
  test "没选 registry 凭据时，不带尾换行的 kamal_secrets 原样写出，一个字节都不多" do
    Dir.mktmpdir("kamal-panel-writetest-") do |dir|
      app = build_app(kamal_secrets: "RAILS_MASTER_KEY=abc")

      KamalCli::Invocation.new(app).send(:write_project_files, dir)

      assert_equal "RAILS_MASTER_KEY=abc", File.read(File.join(dir, ".kamal", "secrets-common")),
                   "未选 registry 凭据的应用，写出的 secrets-common 应与此前逐字节一致"
    end
  end

  test "两份内容并存时都写进去" do
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
  test "密码里的 dotenv 元字符原样到达 kamal，$(...) 不会被当成命令执行" do
    Dir.mktmpdir("kamal-panel-hooktest-") do |probe|
      marker = File.join(probe, "hook-ran")
      secret = "p@ss#word $(id) $HOME back\\slash "
      app = env_dumping_app(marker, config_yaml: CUSTOM_REGISTRY_ENV_YAML)
      app.update!(registry_credential: RegistryCredential.create!(name: "Docker Hub", value: secret))

      KamalCli::Invocation.new(app).run(%w[app details --version v1]) { |_| }

      dumped = File.read(marker)
      assert_match(/^MY_OWN_REGISTRY_TOKEN=#{Regexp.escape(secret)}$/, dumped,
                   "密码应逐字节到达 kamal：截断、反转义、插值、命令替换一个都不能发生")
      refute_match(/^MY_OWN_REGISTRY_TOKEN=.*uid=\d+/, dumped,
                   "$(id) 绝不能在面板这台机器上被执行")
    end
  end

  test "子进程看不到面板的敏感环境变量" do
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
      refute_includes dumped, "panel-master-key-marker", "RAILS_MASTER_KEY 不得进入子进程"
      refute_includes dumped, "panel-ar-key-marker", "AR_ENCRYPTION_* 不得进入子进程"
      assert_match(/^SSH_AUTH_SOCK=/, dumped, "白名单里该有的东西还得在")
      assert_match(/^PATH=/, dumped)
    end
  end

  test "调用方块里的异常按原样抛出，而不是被吞成一次超时" do
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
    assert_operator elapsed, :<, 60, "调用方块出错时应立即终止子进程，而不是等满超时"
  end

  test "被信号杀死的子进程也返回 Integer 退出码" do
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
