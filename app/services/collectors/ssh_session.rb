require "net/ssh"
require "timeout"

# 对被管应用的 SSH 访问。
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

    # 不用 Net::SSH.start 的块形式：它的 ensure 不受 Timeout 保护，实测 sleep 30 要等满 30 秒。
    def capture(host, command)
      session = connect(host)

      begin
        Timeout.timeout(execution_timeout) { session.exec!(command).to_s }
      ensure
        close_session(session)
      end
    end

    # 对多台主机执行命令。
    # 不会中断其他主机（spec 6.4：失联要显式呈现，不能让整轮采集失败）。
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

      # 不管连接+认证的总时长，这里用 Timeout 包一个总截止时间。
      def connect(host)
        Timeout.timeout(connect_timeout) { Net::SSH.start(host, ssh_user, **net_ssh_options) }
      end

      # 走跳板机时 socket 是 IO.popen 包着子进程的 IO，它的 close 会 Process.wait，所以这里也要设限。
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
          # 显式关掉 net-ssh 对 ~/.ssh/config（以及 /etc/ssh_config）的读取。
          config: false
        }.compact
      end
  end
end
