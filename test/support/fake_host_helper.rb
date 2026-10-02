require "net/ssh"
require "shellwords"

module FakeHost
  NODES = { "node-1" => 2201, "node-2" => 2202 }.freeze
  KEY_PATH = Rails.root.join("test/fake_host/id_ed25519")
  PROXY_IMAGE = "basecamp/kamal-proxy:v0.10.0".freeze

  class NotReady < StandardError; end

  # git 只保留可执行位，所以这把测试密钥从仓库 checkout 出来时是 0644，
  # 而 OpenSSH 客户端【拒绝】使用组/他人可读的私钥。
  # 走 net-ssh（Ruby）的测试不受影响——它不做这项 OS 检查——
  # 但任何调真实 ssh / kamal 二进制的测试都会以「Permission denied (publickey)」失败，
  # 且失败信息完全不指向权限。CI workflow 有一步 chmod 600 正是为此；
  # 本地开发没有那一步，所以在这里自动修正。
  def self.ensure_key_mode!
    mode = File.stat(KEY_PATH).mode & 0o777
    File.chmod(0o600, KEY_PATH) unless mode == 0o600
  end

  def self.private_key
    File.read(KEY_PATH)
  end

  def self.ssh_options
    {
      keys: [ KEY_PATH.to_s ],
      keys_only: true,
      auth_methods: [ "publickey" ],
      verify_host_key: :never,
      timeout: 5
    }
  end

  def self.ssh(node, command)
    port = NODES.fetch(node)
    Net::SSH.start("127.0.0.1", "deploy", **ssh_options, port: port) do |session|
      session.exec!(command).to_s
    end
  end

  # 记住就绪状态——但只记住「成功」。fake host 一旦就绪，在一次测试进程运行期间
  # 不会中途掉线，没必要每个测试都为它开 2 条 SSH 连接；但如果第一次探测时容器
  # 还没起来，不能把这个「暂时未就绪」永久记成失败，否则本地开发时容器起来晚了
  # 就会一直误报 fixture 坏掉。所以失败分支每次都重新探测。
  def self.ready?
    return true if @ready

    NODES.each_key do |node|
      # `ssh` (net-ssh's exec!) does not surface the remote command's exit
      # status, so we can't rely on "docker info >/dev/null && echo ok"
      # raising when docker info fails — we have to check the actual output.
      raise NotReady unless ssh(node, "docker info >/dev/null && echo ok").strip == "ok"
    end
    @ready = true
  rescue StandardError
    false
  end

  def self.ensure_ready!
    ensure_key_mode!
    return if ready?

    raise NotReady, <<~MSG
      fake host 未就绪。请先启动：
        docker compose -f docker-compose.test.yml up -d --build
    MSG
  end

  # 直接探测单个节点，不经过、也不写 @ready 那个"全体只需成功一次"的
  # 记忆化标记。故障注入测试会真的把某一台节点停掉再拉起来，这时候
  # 需要回答的是"这一台现在到底通不通"，而 #ready? 一旦见过一次成功
  # 就永远返回 true（哪怕这台节点此刻正在重启），用来做"重启后是否
  # 已经恢复"的判断会直接失真。
  def self.node_ready?(node)
    ssh(node, "docker info >/dev/null && echo ok").strip == "ok"
  rescue StandardError
    false
  end

  def self.wait_until_node_ready!(node, timeout: 60)
    deadline = Time.now + timeout
    until node_ready?(node)
      raise NotReady, "#{node} 在 #{timeout} 秒内未能恢复就绪" if Time.now > deadline
      sleep 1
    end
  end

  # 按 Kamal 的命名与标签约定造一个容器。
  # 容器名格式来自 Kamal::Configuration::Role#container_name:
  #   [service, role, destination].compact.join("-") + "-" + version
  #
  # 这几个参数（尤其 service/destination/role）拼进的是一条经 SSH 发给远端
  # shell 执行的命令——目前调用方全部传字面量，没有一处来自不可信输入，
  # 所以今天不构成注入面；但这个 helper 是 Task 6-8 都会依样画葫芦的模板，
  # 如果它们将来把 ManagedApp 的字段（哪怕是已经校验过的 destination）传
  # 进来，"这里本来就该转义"不该是靠读这段代码才知道的事。所以无论今天
  # 用不用得上，都用 Shellwords.escape 转义每一个拼进命令行的值。
  def self.seed_container(node:, service:, role:, destination:, version:, state: :running)
    name = [ service, role, destination, version ].compact.join("-")

    escaped_name = Shellwords.escape(name)
    escaped_service = Shellwords.escape(service)
    escaped_destination = Shellwords.escape(destination.to_s)
    escaped_role = Shellwords.escape(role)

    ssh node, <<~SH
      docker run -d --name #{escaped_name} \
        --label service=#{escaped_service} \
        --label destination=#{escaped_destination} \
        --label role=#{escaped_role} \
        busybox:latest sleep 3600
    SH

    ssh(node, "docker stop #{escaped_name}") if state == :stopped

    name
  end

  def self.start_proxy(node)
    ssh node, <<~SH
      docker run -d --name kamal-proxy \
        --restart unless-stopped \
        --publish 8080:80 \
        #{Shellwords.escape(PROXY_IMAGE)}
    SH

    # 等 proxy 的 RPC socket 就绪
    20.times do
      return if ssh(node, "docker exec kamal-proxy kamal-proxy list --json 2>/dev/null").present?
      sleep 0.5
    end

    raise NotReady, "kamal-proxy 在 #{node} 上未能就绪"
  end

  def self.proxy_deploy(node:, service:, target:)
    escaped_service = Shellwords.escape(service)
    escaped_target = Shellwords.escape(target)

    ssh node, "docker exec kamal-proxy kamal-proxy deploy #{escaped_service} --target #{escaped_target} --force"
  end

  def self.reset!(node)
    ssh node, "docker ps -aq | xargs -r docker rm -f"
  end

  def self.reset_all!
    NODES.each_key { |node| reset!(node) }
  end
end
