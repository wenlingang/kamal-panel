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

  # 只把 registry 密码引用的变量名换成一个非默认值——这正是这组新测试要
  # 钉住的地方：一个写死 KAMAL_REGISTRY_PASSWORD 的实现会在这里当场变红。
  # 端口沿用 BASE_YAML 的，否则连不上 FakeHost。
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

  # 一个把自己被调用这件事写到盘上的 hook。写的是 `env`：一份 dump 同时能
  # 回答三个问题——hook 到底跑了没有、`.kamal/secrets` 到底可达没有、
  # 子进程到底看得见面板的哪些环境变量。
  def env_dumping_app(marker_path, hook: "pre-connect", **attrs)
    build_app(
      kamal_hooks: { hook => "#!/bin/sh\nenv > #{marker_path}\n" }.to_json,
      **attrs
    )
  end

  test "能对真实主机跑通一条只读的 kamal 命令——且认证确实只靠 ssh-agent" do
    # 这条测试的承重断言不是"有输出"，而是"输出里有那个只能通过 SSH +
    # docker 才能看到的容器名"。
    #
    # 没有这个断言时，一次【认证失败】也会让测试通过：不给 agent 时
    # `kamal app details` 打印 "deploy@127.0.0.1's password:" 加一条
    # SSHKit::Runner::ExecuteError，照样是"若干行输出 + 一个 Integer 退出码"。
    # 而"只靠 agent、不落盘、不给 ssh -i 也能认证"是整个计划的承重前提，
    # 它必须有一条会因为它不成立而变红的测试。
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

    # 必须在 run 的块内、tempdir 被清理之前读取文件内容——run 返回之后
    # Dir.mktmpdir 已经删掉了整个目录，这时再读只会读到 ENOENT。
    #
    # 扫的范围刻意比"面板自己的临时目录"大：$TMPDIR 全树（含点文件）
    # 加上 ~/.ssh。只盯 kamal-panel-*/**/* 的话，一个写到 $TMPDIR 根下的
    # Tempfile、或者一个写成 .ssh/id_ed25519 的点文件（Dir.glob 的 **/*
    # 默认不匹配点文件）都是看不见的。
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

    # 目录数不变不能证明 agent 死了——「文件系统里没有密钥，但解密后的密钥
    # 仍然通过一个 socket 可达」正是这里最坏的泄漏形状，而它跟目录计数无关。
    agent = invocation.agent
    assert_not_nil agent&.pid
    assert_raises(Errno::ESRCH, "ssh-agent 应已退出") { Process.kill(0, agent.pid.to_i) }
    assert_not File.exist?(agent.auth_sock), "agent 的 socket 应已消失"
  end

  test "超时会杀掉整个进程组并返回 124" do
    # 老测试用 `app logs --follow`，指望它「不会自己退出」。它其实会：临时
    # 目录里没有 git 仓库，kamal 算不出 version，几百毫秒内就带着 123 退出了，
    # 而 `refute_equal 0, status` 对 123 一样通过——超时分支从来没跑过。
    #
    # 这里改成用一个 hook 制造一次【真的】挂起：hook 先把自己的 pid 写下来，
    # 再 sleep。它是 kamal 的孙子进程，于是这条测试同时钉住两件事：
    #   1. 超时分支真的跑了（124 + 那句提示 + 时间上界）；
    #   2. 被杀掉的是整个进程组，不只是 kamal 自己——没有 pgroup 的话这个
    #      sleep 会在面板显示「已终止」之后继续活着（真实场景里它是一条正在
    #      对用户生产机器动手的 ssh/docker）。
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
        # 给内核一点时间收尸
        20.times { Process.kill(0, hook_pid); sleep 0.1 }
      end
    end
  end

  test "kamal 真的加载了 deploy.<destination>.yml 覆盖文件" do
    # 这个项目已经两次修过"连错机器"，而 write_project_files 里一个文件名
    # 打错（deploy-production.yml）不会有任何报错：kamal 只加载基础配置、
    # 照常对【错误的主机】动手，四条老测试全绿。所以这里让覆盖文件里的
    # 主机是一个基础配置里根本没有的地址，再问 kamal 自己算出来的 hosts
    # 是哪一个。`kamal config` 只在本地跑（main.rb:127-132），不连主机。
    app = build_app(destination_config_yaml: <<~YAML)
      servers:
        web:
          - 10.77.77.77
    YAML

    # 临时目录里没有 git 仓库（面板永不接触源码），所以需要 version 的命令
    # 必须显式传 --version，否则 kamal 报 "no git repository found"。
    result = KamalCli::Invocation.new(app).run(%w[config --version v1]) { |_| }

    assert_equal 0, result[:status], result[:output]
    assert_includes result[:output], "10.77.77.77", "应使用 destination 覆盖文件里的主机"
    refute_includes result[:output], "127.0.0.1", "覆盖文件应替换掉基础配置里的主机"
  end

  test "用户自己的 pre/post-deploy hook 确实会被触发" do
    # 「调 CLI 而不是自己拼命令」的全部理由就是让用户的 hook 照常触发。
    # 在这条测试存在之前，那句话只是 invocation.rb 头部注释里的一个断言，
    # 而实现（chdir 进一个空目录）让它必然为假。
    Dir.mktmpdir("kamal-panel-hooktest-") do |probe|
      marker = File.join(probe, "hook-ran")
      app = env_dumping_app(marker)

      # 一旦有 hook，kamal 就必须算出 config.version（KAMAL_VERSION 这个 tag），
      # 而临时目录里没有 git 仓库——所以带 hook 的命令必须显式传 --version。
      result = KamalCli::Invocation.new(app).run(%w[app details --version v1]) { |_| }

      assert File.exist?(marker), "pre-connect hook 应被执行。kamal 输出：\n#{result[:output]}"
      assert_match(/^KAMAL_SERVICE=blog$/, File.read(marker),
                   "hook 应在 kamal 提供的 hook 环境里执行，而不是被别的东西碰巧跑了一下")
    end
  end

  test "kamal 能读到 .kamal/secrets——数组式密码写法可用" do
    # `registry.password: [KAMAL_REGISTRY_PASSWORD]` 是 Kamal 2 的标准写法，
    # 也是这个 fixture 用的写法。secrets 文件不可达时它在 app boot /
    # rollback（Task 7 的目标）上直接抛 ConfigurationError。
    # kamal 自己解析 secrets 文件的最便宜的一条路径就是 run_hook(secrets: true)：
    # 它把 config.secrets.to_h 合并进 hook 的环境。
    Dir.mktmpdir("kamal-panel-hooktest-") do |probe|
      marker = File.join(probe, "hook-ran")
      app = env_dumping_app(marker, kamal_secrets: "KAMAL_REGISTRY_PASSWORD=s3cr3t-from-panel\n")

      KamalCli::Invocation.new(app).run(%w[app details --version v1]) { |_| }

      assert_match(/^KAMAL_REGISTRY_PASSWORD=s3cr3t-from-panel$/, File.read(marker),
                   "kamal 应从面板写出的 .kamal/secrets-common 里读到这个 secret")
    end
  end

  # 变量名取自应用自己的 deploy.yml（CUSTOM_REGISTRY_ENV_YAML 里那个
  # 名字不是 KAMAL_REGISTRY_PASSWORD——写死常量的实现会在这里当场变红）。
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

  # 用 env-dump 标记文件抓不住这条：kamal 把 secrets 合并进 hook 环境时，
  # 一行末尾多没多一个 "\n" 并不影响 `env` 命令的输出。这里要验的是面板
  # 写出的那个文件本身的字节，所以直接调用 write_project_files——它不连
  # 主机，也不需要 kamal 参与，能直接读到 .kamal/secrets-common 的原始内容。
  #
  # kamal_secrets 故意不带尾换行：旧实现是 `File.write(..., kamal_secrets)`
  # 原样写出；如果新实现在只有自由文本这一段时也去补一个分隔换行，这条就会
  # 变红——这正是"未选 registry 凭据的应用逐字节不受影响"这个承诺的检验点。
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

  # 这一条走完整条链路（面板写文件 → kamal 用 dotenv 解析 → hook 环境），
  # 因为要钉住的不是"面板写出了什么字节"，而是"dotenv 最后交给 kamal 的是
  # 不是原来那串密码"。不加引号时 dotenv 会在 # 处截断、剥掉行尾空白、
  # 把 \s 反转义成 s、把 $HOME 插值掉，并且【真的去执行】 $(id)——
  # 后者是在面板这台机器上执行，不是在目标主机上。
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
    # kamal 会对用户的 deploy.yml 做 ERB 求值，也就是说这个子进程里可以跑
    # 攻击者影响的代码。Open3 的 env 参数是合并进 ENV 的，不加
    # unsetenv_others 的话它会拿到 RAILS_MASTER_KEY——一把能解密所有
    # Credential 行（= 其他每个应用的私钥）的钥匙。
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
    # 原来的实现会让这个异常把 reader 线程杀掉、管道不再排空、kamal 卡死，
    # 最后跑满整个 timeout 返回 status 124——Task 7 行处理器里的一个 bug
    # 会被当成「kamal 挂了」报给运维。
    assert_operator elapsed, :<, 60, "调用方块出错时应立即终止子进程，而不是等满超时"
  end

  test "被信号杀死的子进程也返回 Integer 退出码" do
    # exitstatus 对被信号杀死的子进程是 nil，直接返回会破掉文档承诺的
    # `status: Integer` 契约（调用方一个 result[:status].zero? 就是
    # NoMethodError）。按 shell 惯例折算成 128 + signo。
    pid = Process.spawn("sleep", "30", out: File::NULL, err: File::NULL)
    Process.kill("KILL", pid)
    _, process_status = Process.wait2(pid)

    assert_nil process_status.exitstatus
    assert_equal 128 + Signal.list.fetch("KILL"),
                 KamalCli::Invocation.new(build_app).send(:exit_status, process_status)
  end

  private
    # 手写遍历而不用 Dir.glob：$TMPDIR 下有 macOS 自己的 TemporaryItems 之类
    # 当前用户读不了的目录，Dir.glob 撞上它会直接抛 EPERM，整条测试就变成
    # 「因为环境噪音而报错」而不是「检查有没有泄漏」。
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
