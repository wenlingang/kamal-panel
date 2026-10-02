require "open3"
require "fileutils"

module KamalCli
  # A separate ssh-agent for every invocation. The key is injected via stdin (ssh-add -) and is
  # [never written to disk].
  class Agent
    class StartFailed < StandardError; end

    ADD_KEY_TIMEOUT = 10
    STOP_GRACE = 3

    # plus a little margin, rather than a meaninglessly large value.
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
      # socket parsed but no pid = we started an agent we cannot kill.
      # We must raise here, instead of letting the `return if pid.blank?` in stop! quietly leak it.
      raise StartFailed, "无法从 ssh-agent 输出中解析 pid" if @pid.blank?
    end

    def add_key!(private_key, lifetime:)
      env = { "SSH_AUTH_SOCK" => auth_sock }
      output = +""
      status = nil

      Open3.popen2e(env, "ssh-add", "-t", lifetime.to_i.to_s, "-") do |stdin, out, wait_thread|
        # (lesson from plan 01: only the subprocess execution got a timeout, and this write did
        # not).
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
          # a thread still writing into output would outlive this call.
          [ writer, reader ].each { |t| t.kill; t.join }
          raise StartFailed, "ssh-add 超时"
        end

        reader.join
        status = wait_thread.value
      end

      raise StartFailed, "ssh-add 失败：#{output.lines.first}" unless status.success?
    end

    # TERM -> confirm -> KILL, then clean up the agent's own socket directory.
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

      # When ssh-agent exits normally it deletes $TMPDIR/ssh-XXXXXX/ itself; when KILLed it does
      # not. Only delete directories whose shape matches (basename starts with "ssh-"), with no
      # recursive globbing of any kind.
      def cleanup_socket_dir
        return if auth_sock.blank?

        dir = File.dirname(auth_sock)
        return unless File.basename(dir).start_with?("ssh-")
        return unless File.directory?(dir)

        FileUtils.remove_entry(dir, true)
      end
  end
end
