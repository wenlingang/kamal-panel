require "open3"
require "json"

# Do not pre-judge "whether it has a passphrase" in order to skip the subprocess: a home-made reader
# and net-ssh understand malformed input differently, and a real bypass has happened.
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

    # Returns [stdout, timed_out].
    def run_subprocess
      input = JSON.generate(value: value)
      stdout = nil
      timed_out = false

      Open3.popen3(*command) do |stdin, out, err, wait_thread|
        # Write stdin, read stdout, read stderr each on its own thread, and they must be started
        # before wait_thread.join. Measured: for a subprocess that never reads stdin, a synchronous
        # write blocked for 117.85 seconds, and wrapping it in Timeout from outside could not stop
        # it either.
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
