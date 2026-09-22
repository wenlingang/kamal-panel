require "open3"
require "json"
require "tmpdir"
require "pathname"
require "net/ssh/proxy/jump"
require "resolv"

# 在受限子进程中解析 deploy.yml。
class Kamal::ConfigParser
  class ParseError < StandardError; end

  DEFAULT_TIMEOUT = 5.seconds
  SCRIPT = Rails.root.join("bin/parse_deploy_config").to_s
  TMPDIR_PREFIX = "kamal-panel-parse"

  # destination 里出现 "/" 或 ".." 就是任意文件写入 + 任意 .yml 被 ERB 求值。
  DESTINATION_FORMAT = /\A(?!-)[a-zA-Z0-9_-]{1,63}\z/

  SERVICE_FORMAT = DESTINATION_FORMAT

  # 主机名/IPv4 字符集：字母数字、点、下划线、连字符。
  HOST_FORMAT = /\A(?!-)[A-Za-z0-9_.-]{1,255}\z/

  # IPv6 字符集交给 Resolv::IPv6::Regex，手写正则容易漏掉 "::" 压缩与嵌入 IPv4。
  IPV6_ZONE_ID = "%"

  # 方括号包住的 IPv6 字面量，可选带 ":port"——"[::1]"、"[::1]:2222"。
  BRACKETED_IPV6_FORMAT = /\A\[(?<addr>[^\]]*)\](?::(?<port>[0-9]{1,5}))?\z/

  # 这类 SSHKit 认识但面板暂不支持的写法（报"暂不支持"）。
  HOST_WITH_USER_OR_PORT_FORMAT = /\A(?:(?!-)[A-Za-z0-9_.-]{1,64}@)?(?!-)[A-Za-z0-9_.-]{1,255}(?::[0-9]{1,5})?\z/

  # ssh.proxy：可选 "user@" + host（复用 HOST_FORMAT 字符集）+ 可选 ":port"。
  PROXY_FORMAT = /\A(?:(?<user>(?!-)[A-Za-z0-9_.-]{1,64})@)?(?<host>(?!-)[A-Za-z0-9_.-]{1,255})(?::(?<port>[0-9]{1,5}))?\z/

  PORT_FORMAT = /\A[1-9][0-9]{0,4}\z/

  def self.call(yaml:, destination: nil, destination_yaml: nil, timeout: DEFAULT_TIMEOUT)
    new(yaml:, destination:, destination_yaml:, timeout:).call
  end

  def initialize(yaml:, destination:, destination_yaml:, timeout:)
    @yaml = yaml
    @destination = destination
    @destination_yaml = destination_yaml
    @timeout = timeout
  end

  def call
    Dir.mktmpdir(TMPDIR_PREFIX) do |dir|
      write_config_files(dir)

      result = JSON.parse(run_subprocess(dir))
      raise ParseError, result["error"] unless result["ok"]

      validate_service!(result["service"])
      validate_hosts!(result)
      result["ssh_options"] = build_ssh_options(result["ssh_options"])

      Kamal::ParsedConfig.new(result)
    end
  rescue JSON::ParserError => e
    raise ParseError, "子进程返回了无法解析的输出：#{e.message}"
  end

  private
    attr_reader :yaml, :destination, :destination_yaml, :timeout

    def write_config_files(dir)
      config_path(dir).write(yaml)

      return if destination.blank?

      validate_destination!
      destination_path(dir).write(destination_yaml.presence || "{}")
    end

    def validate_destination!
      return if destination.is_a?(String) && destination.match?(DESTINATION_FORMAT)

      raise ParseError, "destination 不合法：只能是字母、数字、下划线或连字符组成的短标识符（最多 63 个字符），" \
                         "不能包含路径分隔符或点"
    end

    def validate_service!(service)
      # 同 validate_destination!：公开 API，不能假设调用方给得出合法 String。
      return if service.is_a?(String) && service.match?(SERVICE_FORMAT)

      raise ParseError, "service 不合法：只能是字母、数字、下划线或连字符组成的短标识符（最多 63 个字符），" \
                         "不能包含路径分隔符或点"
    end

    def config_path(dir)
      Pathname.new(dir).join("deploy.yml")
    end

    # servers: 里的主机名来自用户粘贴的 deploy.yml，Kamal 只校验 String/Hash 形状。
    def validate_hosts!(result)
      hosts = Array(result["app_hosts"]).dup
      hosts << result["primary_host"] if result["primary_host"]
      Array(result["roles"]).each { |role| hosts.concat(Array(role["hosts"])) }

      hosts.uniq.each do |host|
        next if valid_host?(host)

        if host.is_a?(String) && (HOST_WITH_USER_OR_PORT_FORMAT.match?(host) || valid_bracketed_ipv6?(host))
          raise ParseError, "servers 里的 #{host.inspect} 暂不支持：面板目前还不支持在 servers: 里给" \
                             "单台主机单独指定 user 或 port（SSHKit 的 user@host / host:port /" \
                             "user@host:port 写法）。这不是配置错误——如果需要覆盖，请暂时写在" \
                             "ssh: 段（对所有主机生效）；每台主机单独覆盖是计划中的后续功能。"
        end

        raise ParseError, "servers 里的主机名/IP 不合法（#{host.inspect}）：只能是 IPv4/主机名" \
                           "（字母、数字、点、下划线、连字符，不能以连字符开头），或裸 IPv6 地址" \
                           "（不带方括号、不带端口，如 \"::1\"）"
      end
    end

    # servers: 里一台主机的合法形状：IPv4/主机名（HOST_FORMAT）、裸 IPv6。
    def valid_host?(host)
      return false unless host.is_a?(String)

      HOST_FORMAT.match?(host) || valid_ipv6?(host)
    end

    def valid_ipv6?(address)
      return false if address.include?(IPV6_ZONE_ID)

      Resolv::IPv6::Regex.match?(address)
    end

    def valid_bracketed_ipv6?(host)
      match = BRACKETED_IPV6_FORMAT.match(host)
      return false unless match
      return false unless valid_ipv6?(match[:addr])
      return true if match[:port].nil?

      match[:port].to_i.between?(1, 65535)
    end

    def build_ssh_options(raw_ssh_options)
      if raw_ssh_options["proxy_command_present"]
        raise ParseError, "ssh.proxy_command 不受支持：面板拒绝执行配置文件里指定的本地命令。" \
                           "如果需要经跳板机连接，请改用 ssh.proxy（格式：[user@]host[:port]，仅支持单跳）。"
      end

      {
        "user" => raw_ssh_options["user"],
        "port" => build_port(raw_ssh_options["port"]),
        "proxy" => build_proxy(raw_ssh_options["proxy"])
      }
    end

    def build_port(raw_port)
      str = raw_port.to_s

      unless PORT_FORMAT.match?(str) && str.to_i.between?(1, 65535)
        raise ParseError, "ssh.port 不合法：只能是 1-65535 之间的纯数字端口号（当前值：#{raw_port.inspect}）"
      end

      str.to_i
    end

    def build_proxy(proxy_spec)
      return nil if proxy_spec.blank?

      raise ParseError, "ssh.proxy 不合法：只支持单跳跳板机，不能包含逗号" if proxy_spec.include?(",")

      unless PROXY_FORMAT.match?(proxy_spec)
        raise ParseError, "ssh.proxy 不合法：格式必须是 [user@]host[:port]，" \
                           "且只能使用字母、数字、点、下划线、连字符"
      end

      jump_spec = proxy_spec.include?("@") ? proxy_spec : "root@#{proxy_spec}"
      Net::SSH::Proxy::Jump.new(jump_spec)
    end

    def destination_path(dir)
      path = config_path(dir).sub_ext(".#{destination}.yml")
      expected_dir = Pathname.new(dir).expand_path

      unless path.expand_path.dirname == expected_dir
        raise ParseError, "destination 解析出的路径超出了临时目录范围，已拒绝"
      end

      path
    end

    def command
      [ RbConfig.ruby, SCRIPT ]
    end

    def run_subprocess(dir)
      input = JSON.generate(config_file: config_path(dir).to_s, destination: destination.presence)
      stdout = nil

      Open3.popen3(*command) do |stdin, out, err, wait_thread|
        # 任一方超过管道缓冲区都会阻塞父进程，而那个阻塞在 join(timeout) 生效之前，硬超时拦不住。
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

        unless wait_thread.join(timeout)
          Process.kill("KILL", wait_thread.pid)
          wait_thread.join
          stdin_writer.kill
          stdout_reader.kill
          stderr_reader.kill
          raise ParseError, "解析超时（#{timeout} 秒）。deploy.yml 中可能有耗时的 ERB。"
        end

        stdin_writer.join
        stdout = stdout_reader.value
        stderr = stderr_reader.value

        if stdout.blank?
          raise ParseError, "解析子进程无输出。stderr: #{stderr.truncate(500)}"
        end
      end

      stdout
    end
end
