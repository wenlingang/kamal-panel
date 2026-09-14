require "open3"
require "tmpdir"
require "fileutils"

module KamalCli
  # 在受限子进程中执行 kamal CLI。
  #
  # 为什么调 CLI 而不是自己用 Kamal::Commands::App 拼命令：
  # kamal rollback 不只是启动容器——它还会触发用户自己的 pre/post-deploy hook、
  # 切换 kamal-proxy 路由、跑健康检查。自己重实现等于再造一个必须与 Kamal
  # 永远保持一致的实现，而计划 01 已经为「两个必须永远同意的实现」付过学费。
  #
  # 临时目录由【父进程】拥有并在 ensure 中清理——子进程可能被 SIGKILL，
  # 它的 ensure 不会运行（计划 01 Task 3 的教训）。
  #
  # ## 临时目录是一个完整的 kamal 项目目录，不是一个只放了 deploy.yml 的空目录
  #
  # Kamal 有三样东西按【当前工作目录】相对路径解析，而不是相对 --config-file：
  #
  #   - hooks_path，默认 ".kamal/hooks"（configuration.rb:268）
  #   - secrets_path，默认 ".kamal/secrets"（configuration.rb:273）
  #   - git 仓库（用于 config.version 的 commit hash，configuration.rb:98）
  #
  # 早先这里 chdir 进一个只写了 deploy.yml 的空临时目录，后果是：
  #   1. 用户的 pre/post-deploy hook 一次都不会触发（hook_exists? 为 false 时
  #      run_hook 是静默 no-op）——而"让用户 hook 照常触发"正是上面那段
  #      "为什么调 CLI"的【全部理由】，注释因此是假的；
  #   2. `registry.password: [KAMAL_REGISTRY_PASSWORD]`（Kamal 2 的标准写法）
  #      在 `app boot` / `rollback` 里报 "Secret not found, no secret files
  #      (.kamal/secrets…) provided"——也就是面板要支持的每一个写操作都会失败。
  #
  # 所以现在按用户项目的真实布局把整个目录铺出来：
  #
  #   <tmp>/config/deploy.yml           ← ManagedApp#config_yaml
  #   <tmp>/config/deploy.<dest>.yml    ← ManagedApp#destination_config_yaml
  #   <tmp>/.kamal/secrets-common       ← ManagedApp#kamal_secrets
  #   <tmp>/.kamal/hooks/<name>         ← ManagedApp#kamal_hooks_scripts
  #
  # secrets 写的是 `secrets-common` 而不是 `secrets`：Kamal 找的两个文件名是
  # "<path>-common" 和 "<path>.<destination>"（secrets.rb:44）——带 destination
  # 时它【根本不读】裸的 `.kamal/secrets`。面板只持有一份 secrets blob，
  # 写进 `-common` 是唯一在"有 destination"和"无 destination"两种情况下都会被
  # 读到的名字。
  #
  # 仍然做不到的一件事：git 仓库。面板永不接触源码（README），临时目录里没有
  # 也不可能有用户的 git 历史，所以任何需要 config.version 的命令（app boot、
  # rollback 不带版本号）必须由调用方显式传 `--version`，否则 kamal 会报
  # "Can't use commit hash as version, no git repository found"。
  #
  # ## kamal 2.12.0 怎么定位配置
  #
  # class_option :config_file（别名 -c，默认 "config/deploy.yml"），没有
  # KAMAL_CONFIG_DIR 这个环境变量。destination 对应的覆盖文件由
  # Configuration.destination_config_file 通过
  # base_config_file.sub_ext(".#{destination}.yml") 自动算出、自动加载，
  # 不需要我们再传第二个文件参数。
  class Invocation
    DEFAULT_TIMEOUT = 10.minutes

    # 临时目录前缀。刻意与 Kamal::ConfigParser::TMPDIR_PREFIX（"kamal-panel-parse"）
    # 不共享前缀，否则测试里那种"数一数临时目录还剩几个"的断言会被另一条
    # 完全无关的代码路径影响。
    TMPDIR_PREFIX = "kamal-panel-run-"

    # 子进程退出后，还允许 grandchild 继续持有管道写端多久。
    READER_GRACE = 5

    # output 的上限。逐行 yield 的那份数据是完整的；这里这份只是给审计
    # 摘要用的副本，`kamal app logs` 遇上一个话多的应用能把它撑到几百 MB，
    # 那会直接把一个 worker 的堆吃掉。
    MAX_OUTPUT_BYTES = 1_000_000
    TRUNCATED_NOTICE = "\n[面板] 输出过长，后续内容仅逐行推送，未计入摘要\n".freeze
    TIMEOUT_NOTICE = "\n[面板] 执行超时，已终止".freeze
    TIMEOUT_STATUS = 124

    # 子进程能看见的环境变量白名单。Open3 的 env 参数是【合并】进 ENV 的，
    # 不是替换——不加 unsetenv_others 的话，子进程会拿到面板的全部环境，
    # 包括 RAILS_MASTER_KEY / AR_ENCRYPTION_* / DATABASE_URL。而 kamal 会对
    # 用户的 deploy.yml 做 ERB 求值（configuration.rb:38-44），也就是说
    # 受攻击者影响的代码会拿到一把能解密【所有】Credential 行（= 其他每个
    # 应用的私钥）的钥匙。所以这里显式列白名单。
    #
    # BUNDLE_GEMFILE / RUBYOPT / GEM_HOME / GEM_PATH 是刻意留下的：它们让
    # `kamal` 这个 binstub 解析到【面板 Gemfile.lock 锁定的那个】kamal 版本，
    # 而不是宿主机上恰好装了的某个版本。它们不含凭据。
    ENV_ALLOWLIST = %w[
      PATH HOME LANG LC_ALL LC_CTYPE TZ TMPDIR
      GEM_HOME GEM_PATH BUNDLE_GEMFILE RUBYOPT RUBYLIB
    ].freeze

    def initialize(managed_app, timeout: DEFAULT_TIMEOUT)
      @managed_app = managed_app
      @timeout = timeout
    end

    # 最后一次 run 使用的 ssh-agent。对外只读，给测试和诊断用：
    # 「agent 被清理了」这件事在没有它的时候是无法断言的（而它正是
    # 「文件系统里没有密钥，但解密后的密钥仍然可达」那一类泄漏）。
    attr_reader :agent

    # 逐行 yield 子进程输出；返回 { status:, output: }
    def run(args, &block)
      Dir.mktmpdir(TMPDIR_PREFIX) do |dir|
        write_project_files(dir)

        # agent 里的密钥生命周期比这次调用略长即可：父进程被 SIGKILL 时
        # ensure 不会运行，剩下的孤儿 agent 会自己在这个时限后忘掉密钥。
        Agent.with(private_key, lifetime: timeout.to_i + 60) do |agent|
          @agent = agent
          execute(dir, agent.auth_sock, args, &block)
        end
      end
    end

    private
      attr_reader :managed_app, :timeout

      def private_key
        managed_app.ssh_credential&.value or raise ArgumentError, "该应用未配置 SSH 私钥"
      end

      def config_file_path(dir)
        File.join(dir, "config", "deploy.yml")
      end

      def write_project_files(dir)
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(config_file_path(dir), managed_app.config_yaml)

        if managed_app.destination.present?
          overlay = managed_app.destination_config_yaml.presence || "{}"
          File.write(File.join(dir, "config", "deploy.#{managed_app.destination}.yml"), overlay)
        end

        write_dot_kamal(dir)
      end

      def write_dot_kamal(dir)
        dot_kamal = File.join(dir, ".kamal")
        FileUtils.mkdir_p(dot_kamal, mode: 0o700)

        secrets = secrets_common_content
        if secrets.present?
          File.write(File.join(dot_kamal, "secrets-common"), secrets)
          File.chmod(0o600, File.join(dot_kamal, "secrets-common"))
        end

        hooks = managed_app.kamal_hooks_scripts
        return if hooks.empty?

        hooks_dir = File.join(dot_kamal, "hooks")
        FileUtils.mkdir_p(hooks_dir, mode: 0o700)

        hooks.each do |name, body|
          # name 已经被 ManagedApp::KAMAL_HOOK_NAMES 收成封闭集合；这里再
          # 拼一次 File.join 时不做任何通配/转义，是因为它不可能含 "/"。
          path = File.join(hooks_dir, name)
          File.write(path, body)
          File.chmod(0o700, path)
        end
      end

      # secrets-common 有两个来源：应用自己那段自由文本，以及（如果选了）
      # registry 凭据。后者按【应用 deploy.yml 实际引用的那个变量名】写入，
      # 不是常量——见 Kamal::ParsedConfig#registry_password_env。
      #
      # 没选 registry 凭据时，这里的行为与此前逐字节一致，未迁移的应用不受
      # 任何影响。
      # 只有一段内容时原样返回，一个字节都不改——这是"没选 registry 凭据
      # 的应用完全不受影响"这个承诺的唯一依据。只有两段都在、需要拼接时，
      # 才在中间补一个分隔用的换行。
      def secrets_common_content
        free_text = managed_app.kamal_secrets.presence
        line = registry_secret_line

        return free_text if line.nil?
        return "#{line}\n" if free_text.nil?

        separator = free_text.end_with?("\n") ? "" : "\n"
        "#{free_text}#{separator}#{line}\n"
      end

      def registry_secret_line
        return @registry_secret_line if defined?(@registry_secret_line)

        @registry_secret_line =
          if managed_app.registry_credential && (env = managed_app.parsed_config.registry_password_env).present?
            # 单引号是这里唯一安全的写法：Kamal 用 dotenv 解析
            # .kamal/secrets-common，而【不加引号】的值会被 dotenv 在 # 处截断、
            # 剥掉行尾空白、把 \X 反转义成 X、按 $FOO 做插值，甚至把 $(...)
            # 当成命令【在面板这台机器上执行】。单引号的值 dotenv 既不反转义
            # 也不做任何替换，原样交给 kamal。自由文本那一半是用户自己写的、
            # 也由用户自己负责引号；这一行是面板拼的，引号就得面板来加。
            # 值里不可能出现单引号或换行——RegistryCredential 在保存时就拒了，
            # 因为 dotenv 的单引号形式对这两个字符没有可用的转义。
            "#{env}='#{managed_app.registry_credential.value}'"
          end
      end

      def child_env(auth_sock)
        ENV_ALLOWLIST.index_with { |key| ENV[key] }.compact.merge("SSH_AUTH_SOCK" => auth_sock)
      end

      def execute(dir, auth_sock, args, &block)
        cmd = [ "kamal", *args, "--config-file", config_file_path(dir) ]
        cmd += [ "--destination", managed_app.destination ] if managed_app.destination.present?

        output = +""
        status = nil
        block_error = nil

        # pgroup: true —— 子进程自成一个进程组。超时时只 kill 直接子进程，
        # kamal 自己 fork 出来的 ssh / docker / hook 会活下来，继续对【用户的
        # 生产机器】动作；面板这边已经显示「已终止」。一个报告"已停止"但其实
        # 还在跑的操作，比它本来要防的那个超时更糟。
        # unsetenv_others: true —— 见 ENV_ALLOWLIST。
        Open3.popen2e(child_env(auth_sock), *cmd,
                      chdir: dir, unsetenv_others: true, pgroup: true) do |stdin, out, wait_thread|
          # 我们不向子进程 stdin 写任何东西，立即关闭即可——没有写入就没有
          # 「写阻塞」的窟窿。真要写东西的地方（ssh-add）在 Agent 里单独限时。
          stdin.close

          reader = Thread.new do
            Thread.current.report_on_exception = false

            begin
              out.each_line do |line|
                append_output(output, line)

                begin
                  block&.call(line.chomp)
                rescue StandardError => e
                  # 调用方块里的异常【不能】被当成超时。原来的写法是让它把
                  # reader 线程杀死，于是管道不再排空、kamal 卡在 write 上，
                  # wait_thread.join 跑满整个 10 分钟，最后返回 status 124——
                  # Task 7 的行处理器里一个 bug 会被当成「kamal 挂了」报给运维。
                  block_error = e
                  break
                end
              end
            rescue IOError, Errno::EIO
              # 管道被关闭（超时分支会主动 close 来解开这个线程），正常结束
            end

            if block_error
              # 立刻终止，而不是让子进程把 timeout 跑满
              signal_group(wait_thread.pid, "KILL")
              # 继续排空管道，否则子进程可能卡在 write 上而不响应信号
              begin
                out.read
              rescue IOError, Errno::EIO, Errno::EBADF
                nil
              end
            end
          end

          unless wait_thread.join(timeout)
            signal_group(wait_thread.pid, "KILL")
            wait_thread.join
            finish_reader(reader, out)
            return { status: TIMEOUT_STATUS, output: output + TIMEOUT_NOTICE }
          end

          finish_reader(reader, out)
          status = exit_status(wait_thread.value)
        end

        raise block_error if block_error

        { status: status, output: output }
      end

      # 整组一起杀。pgroup: true 让子进程的 pgid 等于它自己的 pid，所以
      # -pid 就是"这一组"。取不到进程组时退回只杀直接子进程，总比不杀好。
      def signal_group(pid, name)
        Process.kill(name, -Process.getpgid(pid))
      rescue Errno::ESRCH, Errno::EPERM, RangeError
        begin
          Process.kill(name, pid)
        rescue Errno::ESRCH
          nil
        end
      end

      # reader.join 不能无界。wait_thread.join 返回只说明 kamal 退出了，
      # 管道 EOF 还要求【每一个】持有写端的进程都关掉它——kamal 会 fork
      # docker buildx / sshkit 的 run_locally / hook，任何一个活得比 kamal 长
      # 的孙子进程都会让 out.each_line 永远阻塞，于是 reader.join 把 Rails
      # 的线程挂死，形状和计划 01 那次 stdin 挂起一模一样，只是换到了读的一侧。
      def finish_reader(reader, out)
        return if reader.join(READER_GRACE)

        begin
          out.close
        rescue IOError
          nil
        end

        return if reader.join(READER_GRACE)

        # Thread#kill 是异步的：不 join 就可能有一个还在往 output 里写、
        # 还在回调调用方块的线程比这次调用活得更久。
        reader.kill
        reader.join
      end

      def append_output(buffer, line)
        return if buffer.bytesize >= MAX_OUTPUT_BYTES

        buffer << line
        buffer << TRUNCATED_NOTICE if buffer.bytesize >= MAX_OUTPUT_BYTES
      end

      # 被信号杀死的子进程 exitstatus 是 nil——直接返回它会让文档承诺的
      # `status: Integer` 契约破掉，调用方一个 `result[:status].zero?`
      # 就是 NoMethodError。按 shell 惯例折算成 128 + signo。
      def exit_status(process_status)
        process_status.exitstatus || (process_status.termsig ? 128 + process_status.termsig : 1)
      end
  end
end
