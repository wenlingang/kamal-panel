require "open3"
require "json"

# 不预判"是不是带密码"以跳过子进程：自制 reader 与 net-ssh 对畸形输入理解不一致，出过真实 bypass。
class SshKeyValidator
  Result = Struct.new(:ok, :encrypted, :fingerprint, :error_class, keyword_init: true) do
    def ok? = ok
    def encrypted? = encrypted
  end

  DEFAULT_TIMEOUT = 3.seconds
  SCRIPT = Rails.root.join("bin/validate_ssh_key").to_s

  def self.call(value, timeout: DEFAULT_TIMEOUT)
    new(value, timeout).call
  end

  def initialize(value, timeout)
    @value = value
    @timeout = timeout
  end

  def call
    stdout, timed_out = run_subprocess

    if timed_out
      return Result.new(ok: false, encrypted: false, error_class: "timed_out")
    end

    if stdout.blank?
      return Result.new(ok: false, encrypted: false, error_class: "empty_output")
    end

    parsed = JSON.parse(stdout)
    Result.new(
      ok: parsed["ok"],
      encrypted: parsed["encrypted"],
      fingerprint: parsed["fingerprint"],
      error_class: parsed["error_class"]
    )
  rescue JSON::ParserError
    Result.new(ok: false, encrypted: false, error_class: "invalid_subprocess_output")
  end

  private
    attr_reader :value, :timeout

    def command
      [ RbConfig.ruby, SCRIPT ]
    end

    # 返回 [stdout, timed_out]。
    def run_subprocess
      input = JSON.generate(value: value)
      stdout = nil
      timed_out = false

      Open3.popen3(*command) do |stdin, out, err, wait_thread|
        # 写 stdin、读 stdout、读 stderr 各起一个线程，且必须在 wait_thread.join 之前启动。
        # 实测：对一个从不读 stdin 的子进程，同步 write 阻塞了 117.85 秒，外层包 Timeout 也拦不住。
        stdin_writer = Thread.new do
          stdin.write(input)
        rescue Errno::EPIPE
          nil
        ensure
          stdin.close
        end

        stdout_reader = Thread.new do
          out.read
        rescue IOError
          nil
        end
        stderr_reader = Thread.new do
          err.read
        rescue IOError
          nil
        end

        if wait_thread.join(timeout)
          stdout = stdout_reader.value
        else
          timed_out = true
          Process.kill("KILL", wait_thread.pid)
          wait_thread.join
          stdin_writer.kill
          stdout_reader.kill
          stderr_reader.kill
        end

        stdin_writer.join
      end

      [ stdout, timed_out ]
    end
end
