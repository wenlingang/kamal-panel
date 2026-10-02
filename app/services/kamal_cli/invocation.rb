require "open3"
require "tmpdir"
require "fileutils"

module KamalCli
  # 临时目录必须是完整的 kamal 项目布局，否则用户 hook 不触发、且 secrets 报 Secret not found。
  class Invocation
    DEFAULT_TIMEOUT = 10.minutes

    # 临时目录前缀。刻意与 Kamal::ConfigParser::TMPDIR_PREFIX（"kamal-panel-parse"）
    TMPDIR_PREFIX = "kamal-panel-run-"

    # 子进程退出后，还允许 grandchild 继续持有管道写端多久。
    READER_GRACE = 5

    MAX_OUTPUT_BYTES = 1_000_000
    TRUNCATED_NOTICE = "\n[面板] 输出过长，后续内容仅逐行推送，未计入摘要\n".freeze
    TIMEOUT_NOTICE = "\n[面板] 执行超时，已终止".freeze
    TIMEOUT_STATUS = 124

    # 子进程能看见的环境变量白名单。
    ENV_ALLOWLIST = %w[
      PATH HOME LANG LC_ALL LC_CTYPE TZ TMPDIR
      GEM_HOME GEM_PATH BUNDLE_GEMFILE RUBYOPT RUBYLIB
    ].freeze

    def initialize(managed_app, timeout: DEFAULT_TIMEOUT)
      @managed_app = managed_app
      @timeout = timeout
    end

    # 最后一次 run 使用的 ssh-agent。
    attr_reader :agent

    def run(args, &block)
      Dir.mktmpdir(TMPDIR_PREFIX) do |dir|
        write_project_files(dir)

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
          # 拼一次 File.join 时不做任何通配/转义，是因为它不可能含 "/"。
          path = File.join(hooks_dir, name)
          File.write(path, body)
          File.chmod(0o700, path)
        end
      end

      # secrets-common 有两个来源：应用自己那段自由文本，以及（如果选了）
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

        # pgroup: true —— 子进程自成一个进程组。
        Open3.popen2e(child_env(auth_sock), *cmd,
                      chdir: dir, unsetenv_others: true, pgroup: true) do |stdin, out, wait_thread|
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
                  block_error = e
                  break
                end
              end
            rescue IOError, Errno::EIO
            end

            if block_error
              signal_group(wait_thread.pid, "KILL")
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

      # reader.join 不能无界。
      def finish_reader(reader, out)
        return if reader.join(READER_GRACE)

        begin
          out.close
        rescue IOError
          nil
        end

        return if reader.join(READER_GRACE)

        # 还在回调调用方块的线程比这次调用活得更久。
        reader.kill
        reader.join
      end

      def append_output(buffer, line)
        return if buffer.bytesize >= MAX_OUTPUT_BYTES

        buffer << line
        buffer << TRUNCATED_NOTICE if buffer.bytesize >= MAX_OUTPUT_BYTES
      end

      def exit_status(process_status)
        process_status.exitstatus || (process_status.termsig ? 128 + process_status.termsig : 1)
      end
  end
end
