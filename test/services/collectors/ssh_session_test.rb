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

  # CONNECT_TIMEOUT only covers the TCP handshake and can't cover the more common real failure of
  # "the command hangs and never returns after connecting" (a hung machine). Here sleep simulates a
  # host that has accepted the connection but never returns during command execution, confirming
  # capture has an independent execution-phase deadline
  # -- rather than blocking forever. execution_timeout is given a very short value only so this
  # test itself doesn't slow down the whole suite; production uses the EXECUTION_TIMEOUT constant.
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

  # net-ssh's :timeout option only covers the wait time for a single packet (round 4 review), not
  # the total duration of the whole "connect + authenticate" phase -- a peer that squeezes out a bit
  # of data before each single-packet timeout but never completes the handshake/authentication can
  # drag the connect phase out indefinitely. Here we don't depend on an SSH server that really hangs
  # like that (troublesome to build), and instead temporarily swap Net::SSH.start itself for a fake
  # that sleeps, verifying the Timeout wrapped around #connect really takes effect -- this tests
  # this class's own fallback mechanism, not net-ssh.
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

  # When going through a jump host (ssh.proxy), the underlying socket isn't a plain TCPSocket but
  # the IO popen'd by IO.popen in Net::SSH::Proxy::Command#open, wrapping a child process; #close on
  # this kind of IO waits for the child to exit, and if the child hangs and doesn't exit #close
  # hangs with it -- and this step happens in capture's ensure (see the comment above
  # close_session), and without its own limit it would cancel out the two deadlines already in
  # effect above. Here we call the private close_session directly (rather than building a whole real
  # jump host connection), using a "hangs forever" fake session to verify this fallback layer itself
  # works.
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
