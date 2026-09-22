require "open3"
require "fileutils"

module KamalCli
  # 每次调用独立的 ssh-agent。密钥经 stdin 注入（ssh-add -），【绝不落盘】。
  class Agent
    class StartFailed < StandardError; end

    ADD_KEY_TIMEOUT = 10
    STOP_GRACE = 3

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
        # （计划 01 的教训：只给子进程执行加超时，没给这次写加超时）。
        writer = Thread.new do
          stdin.write(private_key)
        rescue Errno::EPIPE
        ensure
          stdin.close
        end

        reader = Thread.new { output << out.read.to_s }

        unless writer.join(ADD_KEY_TIMEOUT) && wait_thread.join(ADD_KEY_TIMEOUT)
          begin
            Process.kill("KILL", wait_thread.pid)
          rescue Errno::ESRCH
          end
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
