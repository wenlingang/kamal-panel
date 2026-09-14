require "open3"
require "fileutils"

module KamalCli
  # 每次调用独立的 ssh-agent。密钥经 stdin 注入（ssh-add -），【绝不落盘】。
  #
  # 这条已于 2026-09-06 对真实主机实测：不给 ssh -i、仅靠 agent 即可认证。
  # 若某个环境下不成立，调用方应报错，而不是退回「把密钥写到 0600 文件」。
  #
  # 密钥在 agent 里有【生命周期上限】（ssh-add -t）。理由：父进程被 SIGKILL
  # 时，`Agent.with` 的 ensure 不会运行——ssh-agent 会被 init 收养，带着解密
  # 后的私钥和一个同 uid 任何进程都能用的 socket 无限期活下去。"父进程永远
  # 不会被杀"不是我们能控制的性质（OOM kill、容器重启、运维 kill -9 都会发生），
  # 所以不能把它当成前提。有了 -t，最坏情况从"密钥永久可用"降级为
  # "密钥最多可用一次调用超时的时长"。
  class Agent
    class StartFailed < StandardError; end

    ADD_KEY_TIMEOUT = 10
    # stop! 里 TERM 之后等多久再上 KILL
    STOP_GRACE = 3

    # lifetime：传给 ssh-add -t 的秒数。调用方应给"这次调用最长可能跑多久"
    # 再加一点余量，而不是一个大得没有意义的值。
    def self.with(private_key, lifetime:)
      agent = new
      agent.start!
      agent.add_key!(private_key, lifetime: lifetime)
      yield agent
    ensure
      agent&.stop!
    end

    attr_reader :auth_sock, :pid

    def start!
      out, status = Open3.capture2("ssh-agent", "-s")
      raise StartFailed, "ssh-agent 启动失败" unless status.success?

      @auth_sock = out[/SSH_AUTH_SOCK=([^;]+);/, 1]
      @pid       = out[/SSH_AGENT_PID=(\d+);/, 1]
      raise StartFailed, "无法从 ssh-agent 输出中解析 socket" if @auth_sock.blank?
      # socket 解析出来但 pid 没有 = 我们启动了一个自己杀不掉的 agent。
      # 这时候必须报错，而不是让 stop! 的 `return if pid.blank?` 悄悄泄漏它。
      raise StartFailed, "无法从 ssh-agent 输出中解析 pid" if @pid.blank?
    end

    def add_key!(private_key, lifetime:)
      env = { "SSH_AUTH_SOCK" => auth_sock }
      output = +""
      status = nil

      Open3.popen2e(env, "ssh-add", "-t", lifetime.to_i.to_s, "-") do |stdin, out, wait_thread|
        # 写 stdin 本身也要有界——子进程若不读 stdin，父进程会被无限期挂起
        # （计划 01 的教训：只给子进程执行加超时，没给这次写加超时）。
        writer = Thread.new do
          stdin.write(private_key)
        rescue Errno::EPIPE
          # ssh-add 提前退出，忽略
        ensure
          stdin.close
        end

        reader = Thread.new { output << out.read.to_s }

        unless writer.join(ADD_KEY_TIMEOUT) && wait_thread.join(ADD_KEY_TIMEOUT)
          begin
            Process.kill("KILL", wait_thread.pid)
          rescue Errno::ESRCH
            # 已经退出了
          end
          # kill 之后必须 join：Thread#kill 是异步的，不 join 就可能有一个
          # 还在往 output 里写的线程比这次调用活得更久。
          [ writer, reader ].each { |t| t.kill; t.join }
          raise StartFailed, "ssh-add 超时"
        end

        reader.join
        status = wait_thread.value
      end

      raise StartFailed, "ssh-add 失败：#{output.lines.first}" unless status.success?
    end

    # TERM → 确认 → KILL，然后清掉 agent 自己的 socket 目录。
    # 只发 TERM 而不确认，等于把"agent 真的死了"当成一个没验证过的假设——
    # 而这个 agent 内存里有解密后的私钥。
    def stop!
      return if pid.blank?

      numeric_pid = pid.to_i
      signal!(numeric_pid, "TERM")

      unless wait_for_exit(numeric_pid, STOP_GRACE)
        signal!(numeric_pid, "KILL")
        wait_for_exit(numeric_pid, STOP_GRACE)
      end

      cleanup_socket_dir
    end

    private
      def signal!(numeric_pid, name)
        Process.kill(name, numeric_pid)
      rescue Errno::ESRCH
        # 已经没了，正常
      end

      def wait_for_exit(numeric_pid, seconds)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds

        loop do
          begin
            Process.kill(0, numeric_pid)
          rescue Errno::ESRCH
            return true
          end

          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.05
        end
      end

      # ssh-agent 正常退出时会自己删掉 $TMPDIR/ssh-XXXXXX/；被 KILL 时不会。
      # 只删形状对得上的目录（basename 以 "ssh-" 开头），不做任何递归通配。
      def cleanup_socket_dir
        return if auth_sock.blank?

        dir = File.dirname(auth_sock)
        return unless File.basename(dir).start_with?("ssh-")
        return unless File.directory?(dir)

        FileUtils.remove_entry(dir, true)
      end
  end
end
