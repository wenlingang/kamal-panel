require "net/ssh"
require "timeout"

# SSH access to managed apps.
module Collectors
  class SshSession
    Result = Struct.new(:host, :stdout, :error, keyword_init: true)

    CONNECT_TIMEOUT = 10
    EXECUTION_TIMEOUT = 15
    CLOSE_TIMEOUT = 5

    CONNECTIVITY_ERRORS = [
      Net::SSH::Exception,
      SocketError,
      Timeout::Error,
      IOError,
      Errno::ECONNREFUSED,
      Errno::EHOSTUNREACH,
      Errno::ETIMEDOUT,
      Errno::ECONNRESET,
      Errno::ENETUNREACH
    ].freeze

    def initialize(managed_app, execution_timeout: EXECUTION_TIMEOUT, connect_timeout: CONNECT_TIMEOUT, close_timeout: CLOSE_TIMEOUT)
      @managed_app = managed_app
      @execution_timeout = execution_timeout
      @connect_timeout = connect_timeout
      @close_timeout = close_timeout
    end

    # Do not use the block form of Net::SSH.start: its ensure is not protected by Timeout, and
    # measured, sleep 30 waits the full 30 seconds.
    def capture(host, command)
      session = connect(host)

      begin
        Timeout.timeout(execution_timeout) { session.exec!(command).to_s }
      ensure
        close_session(session)
      end
    end

    # Run a command on multiple hosts. Does not interrupt the other hosts (spec 6.4: unreachability
    # must be shown explicitly, and must not fail the whole collection round).
    def capture_many(hosts)
      hosts.each_with_object({}) do |host, results|
        results[host] =
          begin
            Result.new(host: host, stdout: capture(host, yield(host)), error: nil)
          rescue *CONNECTIVITY_ERRORS => e
            Result.new(host: host, stdout: nil, error: "#{e.class}: #{e.message}")
          rescue StandardError => e
            Rails.logger.error(
              "[Collectors::SshSession] 主机 #{host} 采集时抛出非连通性异常，" \
              "疑似程序缺陷而非连通性问题：#{e.class}: #{e.message}\n" \
              "#{Array(e.backtrace).first(10).join("\n")}"
            )
            Result.new(host: host, stdout: nil, error: "内部错误（非连通性问题，已记录日志）：#{e.class}: #{e.message}")
          end
      end
    end

    private
      attr_reader :managed_app, :execution_timeout, :connect_timeout, :close_timeout

      def ssh_options
        managed_app.parsed_config.ssh_options
      end

      def ssh_user
        ssh_options[:user]
      end

      # Regardless of the total time for connect + auth, wrap it in a Timeout here as an overall
      # deadline.
      def connect(host)
        Timeout.timeout(connect_timeout) { Net::SSH.start(host, ssh_user, **net_ssh_options) }
      end

      # When going through a jump host, the socket is the IO of a subprocess wrapped by IO.popen,
      # and its close does Process.wait, so a limit is needed here too.
      def close_session(session)
        Timeout.timeout(close_timeout) { session.shutdown! }
      rescue StandardError
        nil
      end

      def net_ssh_options
        {
          port: ssh_options[:port],
          proxy: ssh_options[:proxy],
          key_data: [ managed_app.ssh_credential&.value ].compact,
          keys_only: true,
          auth_methods: [ "publickey" ],
          verify_host_key: :never,
          timeout: connect_timeout,
          non_interactive: true,
          # Explicitly turn off net-ssh reading ~/.ssh/config (and /etc/ssh_config).
          config: false
        }.compact
      end
  end
end
