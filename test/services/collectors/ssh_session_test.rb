require "test_helper"

class Collectors::SshSessionTest < ExecutionLayerTest
  def managed_app
    @managed_app ||= begin
      yaml = <<~YAML
        service: blog
        image: example/blog
        servers:
          web:
            - 127.0.0.1
        registry:
          server: registry.example.com
          username: someone
          password:
            - KAMAL_REGISTRY_PASSWORD
        builder:
          arch: amd64
        ssh:
          user: deploy
          port: #{FakeHost::NODES.fetch("node-1")}
      YAML

      ManagedApp.create!(
        name: "blog",
        config_yaml: yaml,
        destination: "production",
        ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key,
                                        name: "blog 的 SSH 私钥")
      )
    end
  end

  test "用 deploy.yml 里声明的 user 和 port 连上真实主机" do
    session = Collectors::SshSession.new(managed_app)

    assert_equal "deploy", session.capture("127.0.0.1", "whoami").strip
  end

  test "能在目标主机上执行 docker" do
    session = Collectors::SshSession.new(managed_app)

    assert_match(/Server:/, session.capture("127.0.0.1", "docker version"))
  end

  test "capture_many 把每台主机的失败单独装起来，不影响其他主机" do
    session = Collectors::SshSession.new(managed_app)

    results = session.capture_many([ "127.0.0.1" ]) { "echo hello" }

    assert_equal "hello", results["127.0.0.1"].stdout.strip
    assert_nil results["127.0.0.1"].error
  end

  # CONNECT_TIMEOUT 只管 TCP 握手，管不到"连上之后命令卡住不返回"这种更
  # 常见的真实故障（卡死的机器）。这里用 sleep 模拟一台已经接受连接、但
  # 命令执行阶段永远不返回的主机，确认 capture 有一个独立的执行期截止时间
  # ——而不是无限阻塞。execution_timeout 传一个很短的值，只是为了不让这条
  # 测试本身拖慢整个套件；生产环境用的是 EXECUTION_TIMEOUT 常量。
  test "capture 对连上之后卡住不返回的主机有执行期截止时间，而不是无限阻塞" do
    session = Collectors::SshSession.new(managed_app, execution_timeout: 2)

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Timeout::Error) do
      session.capture("127.0.0.1", "sleep 30")
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    assert_operator elapsed, :<, 10, "capture 应该在 execution_timeout 附近返回，而不是等满 30 秒的 sleep"
    assert_match(/execution expired/, error.message)
  end

  test "capture_many 里同样受执行期截止时间约束，卡住的主机变成 Result#error 而不是整批挂起" do
    session = Collectors::SshSession.new(managed_app, execution_timeout: 2)

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    results = session.capture_many([ "127.0.0.1" ]) { "sleep 30" }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    assert_operator elapsed, :<, 10
    assert_nil results["127.0.0.1"].stdout
    assert_match(/Timeout::Error/, results["127.0.0.1"].error)
  end

  test "capture_many 遇到非连通性异常（程序缺陷）时仍然隔离到单台主机，但会记录到日志而不是伪装成主机不可达" do
    session = Collectors::SshSession.new(managed_app)
    bug = Class.new(StandardError)

    session.define_singleton_method(:capture) { |*| raise bug, "模拟的编程错误" }

    log_output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = Logger.new(log_output)

    results = session.capture_many([ "127.0.0.1" ]) { "whoami" }

    assert_nil results["127.0.0.1"].stdout
    assert_match(/内部错误/, results["127.0.0.1"].error)
    assert_match(/模拟的编程错误/, results["127.0.0.1"].error)

    logged = log_output.string
    assert logged.present?, "非连通性异常应该被记录到日志，不能只悄悄装进 Result 里"
    assert_match(/疑似程序缺陷/, logged)
  ensure
    Rails.logger = original_logger
  end

  # net-ssh 的 :timeout 选项只管单个包的等待时间（round 4 review），不管
  # "连接 + 认证"这整段过程的总时长——一个每次都能在单包超时之前挤出一点
  # 数据、但永远不完成握手/认证的对端，能把连接阶段拖到无限长。这里不
  # 依赖一台真的会这样卡住的 SSH 服务器（构造起来很麻烦），而是直接把
  # Net::SSH.start 本身临时换成一个会 sleep 的假实现，验证#connect 外面
  # 包的 Timeout 确实生效——这是在测本类自己的兜底机制，不是在测 net-ssh。
  test "connect 阶段（连接 + 认证）整体有截止时间，不只是逐包超时" do
    session = Collectors::SshSession.new(managed_app, connect_timeout: 2)

    original_start = Net::SSH.method(:start)
    Net::SSH.define_singleton_method(:start) { |*, **| sleep 30 }

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Timeout::Error) { session.capture("127.0.0.1", "whoami") }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    assert_operator elapsed, :<, 10, "capture 应该在 connect_timeout 附近返回，而不是等满 30 秒"
  ensure
    Net::SSH.define_singleton_method(:start, original_start)
  end

  # 走跳板机（ssh.proxy）时，底层 socket 不是普通 TCPSocket，而是
  # Net::SSH::Proxy::Command#open 里 IO.popen 出来的、包着子进程的 IO；
  # 这种 IO 的 #close 会等子进程退出，子进程卡住不退出的话 #close 就跟着
  # 卡住——而这一步发生在 capture 的 ensure 里（见 close_session 上方
  # 注释），不单独设限的话会重新抵消前面两段已经生效的截止时间。这里
  # 直接调用私有的 close_session（而不是搭一整套真实的跳板机连接），
  # 用一个"永远卡住"的假 session 验证这层兜底本身有效。
  test "关闭阶段本身也有截止时间：即使 shutdown! 卡住（比如代理场景下 IO.popen 的 #close 要等子进程退出），capture 也不会被拖住" do
    session = Collectors::SshSession.new(managed_app, close_timeout: 1)
    wedged_session = Object.new
    wedged_session.define_singleton_method(:shutdown!) { sleep 30 }

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    session.send(:close_session, wedged_session)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    assert_operator elapsed, :<, 10, "close_session 应该在 close_timeout 附近放弃，而不是等满 30 秒"
  end
end
