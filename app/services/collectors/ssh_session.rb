require "net/ssh"
require "timeout"

# 对被管应用的 SSH 访问。
#
# 连接参数直接取自用户 deploy.yml 的 ssh: 段（spec 6.2）：
# user、port、proxy 全部自动继承，不在面板里重复配置。
# 这样不会出现「kamal 能连、面板连不上」的情况。
#
# proxy（跳板机）的校验和对象构造发生在 Kamal::ConfigParser#build_ssh_options
# 里，不在这里——ssh_options[:proxy] 到这里的时候已经是一个校验过的
# Net::SSH::Proxy::Jump 实例（或 nil），本类不需要也不应该再碰原始字符串。
module Collectors
  class SshSession
    Result = Struct.new(:host, :stdout, :error, keyword_init: true)

    CONNECT_TIMEOUT = 10
    EXECUTION_TIMEOUT = 15
    CLOSE_TIMEOUT = 5

    # 会被 capture_many 当作"连通性问题"呈现给用户的异常：主机不可达、
    # 认证失败、协议错误、执行超时——都是这台主机的问题，不是面板的
    # bug。除此之外的 StandardError（比如本类自己的编程错误）会走
    # capture_many 里另一条 rescue 分支，记日志而不是被悄悄当成
    # "这台主机连不上"（这正是 ssh.proxy 那个 bug 曾经被吞掉的方式）。
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

    # command 会被原样交给远端 sshd 派生的登录 shell 执行（未经本地 shell
    # 解释）。命令本身必须来自代码里的封闭指令集（不允许任意远程 shell
    # 功能）；若命令中拼入了服务名、destination、role、主机名等来自用户
    # 粘贴的 deploy.yml 的值，调用方必须先用 Shellwords.escape 处理，避免
    # 这些值被远端 shell 当作命令的一部分解释。
    #
    # 三段各自有独立的截止时间，理由各不相同：
    #
    # 1. 连接 + 认证（#connect）：net-ssh 的 :timeout 选项只管"每一个包"
    #    的等待时间（Transport::Session 里 `socket.next_packet(mode,
    #    options[:timeout])`），不管连接+认证整个过程的总时长——一个
    #    只要在每次读超时之前挤出一点数据就不会撞上单包超时、但整体
    #    握手/认证永远拖着不完成的对端，能把连接阶段拖到无限长。这里
    #    再包一层 Timeout，给"连上并且认证通过"这件事一个总的截止时间。
    # 2. 执行命令（#exec!）：CONNECT_TIMEOUT/connect_timeout 只管连接
    #    阶段。一台已经接受连接、但命令执行阶段卡住不返回的主机（真实
    #    世界里更常见的失败模式：卡死的机器，而不是拒连）不受它约束，
    #    所以单独再包一层 Timeout，覆盖执行阶段。
    # 3. 关闭连接（#close_session）：见该方法上方的注释——这一段本身也
    #    可能无限阻塞，必须单独设限，否则前两段截止时间形同虚设。
    #
    # 综合起来，capture 总会在有限时间内返回或抛出，不会无限阻塞——
    # Task 7 会在轮询循环里调用它，一台卡住的主机不能拖住所有应用的采集。
    #
    # 故意不用 Net::SSH.start 的块形式（`Net::SSH.start(...) do |s| ... end`）。
    # 那个形式自带 `ensure connection.close`，而 Net::SSH 的 #close 是"优雅
    # 关闭"：`loop(0.1) { channels.any? }`，会一直等到远端把 channel 关掉
    # 为止。如果 Timeout 恰恰是因为远端命令卡住不返回才触发的，块形式在
    # 我们的 Timeout::Error 从 exec! 往外冒的路上，会先经过这个 ensure，
    # 而这个 ensure 本身不受 Timeout 保护——它会老老实实等远端命令真正
    # 结束、channel 真正关闭之后才放行，等于把刚生效的执行期截止时间
    # 完全抵消（实测：Timeout.timeout(2) 包住块形式的整个调用，远端跑
    # `sleep 30` 时 capture 仍然要等满 30 秒才返回，而不是 2 秒）。
    # 改用非块形式手动拿到 session，自己在 ensure 里收尾（#close_session），
    # Timeout 才是真正生效的截止时间。
    def capture(host, command)
      session = connect(host)

      begin
        Timeout.timeout(execution_timeout) { session.exec!(command).to_s }
      ensure
        close_session(session)
      end
    end

    # 对多台主机执行命令。单台失败被装进该主机自己的 Result，
    # 不会中断其他主机（spec 6.4：失联要显式呈现，不能让整轮采集失败）。
    def capture_many(hosts)
      hosts.each_with_object({}) do |host, results|
        results[host] =
          begin
            Result.new(host: host, stdout: capture(host, yield(host)), error: nil)
          rescue *CONNECTIVITY_ERRORS => e
            Result.new(host: host, stdout: nil, error: "#{e.class}: #{e.message}")
          rescue StandardError => e
            # 到这里的都不是"主机不可达"，而是代码本身的错误（比如曾经
            # 发生过的 ssh.proxy 序列化 bug）。仍然不让它中断其他主机的
            # 采集——per-host 隔离的契约不能因为异常类型而破例——但必须
            # 显式记日志，不能只靠 Result#error 里那行字符串（调用方不一定
            # 会把它打印出来），否则一个真实的程序 bug 会长期伪装成
            # "这台主机连不上"。
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

      # user、port 一定存在，不需要 `||` 兜底：bin/parse_deploy_config
      # 读的是 Kamal::Configuration::Ssh#user / #port，这两个方法本身在
      # deploy.yml 没写 ssh.user / ssh.port 时就已经回落到 Kamal 自己的
      # 默认值（"root" / 22），子进程会把这两个键始终显式传出来。这里
      # 再加一层 `|| "root"` / `|| 22` 只是死代码，会掩盖"如果这两个键
      # 真的缺失了，那是上游契约被破坏"这个事实。
      def ssh_user
        ssh_options[:user]
      end

      # 见 capture 上方注释第 1 点：net-ssh 的 :timeout 选项只管单个包，
      # 不管连接+认证的总时长，这里用 Timeout 包一个总截止时间。
      def connect(host)
        Timeout.timeout(connect_timeout) { Net::SSH.start(host, ssh_user, **net_ssh_options) }
      end

      # 优雅关闭（Net::SSH::Connection::Session#close）本身就可能无限
      # 阻塞（见 capture 上方大段注释），换成 #shutdown! 直接关底层
      # socket 之后，一般情况下是非阻塞的——但"一般情况"不包括走跳板机
      # 的连接：ssh.proxy 配置了之后，底层 socket 不是普通 TCPSocket，
      # 而是 Net::SSH::Proxy::Command#open 里 `IO.popen(command_line,
      # "r+")` 返回的、包着一个子进程（跳板 ssh 进程）的 IO。这种 IO 的
      # #close 会等子进程退出（本质上是 Process.wait），如果那个子进程
      # 卡住不退出，#shutdown! 里的 `socket.close` 会跟着卡住——这正好
      # 发生在 ensure 里，如果不单独设限，前面 execution_timeout/
      # connect_timeout 好不容易生效的截止时间会在收尾这一步被重新
      # 抵消。所以这里再包一层 Timeout；超时后放弃等待、直接返回——
      # 代价是可能留下一个没被回收的子进程，但 capture 本身必须能返回，
      # 两害相权取其轻。
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
          # v1 的显式取舍：面板目前没有 known_hosts 管理界面，无法在 UI 上
          # 展示/确认主机指纹，因此暂不校验 host key。计划 03 需要评估补上
          # host key 固定（TOFU 或用户手动录入指纹）。这不是疏漏。
          verify_host_key: :never,
          timeout: connect_timeout,
          non_interactive: true,
          # 显式关掉 net-ssh 对 ~/.ssh/config（以及 /etc/ssh_config）的读取。
          # 不传这个选项的话，net-ssh 默认会去读运行面板这台机器上、操作
          # 面板进程的那个系统账户的 ssh config——这是运维本地的文本，不是
          # 攻击者能控制的输入，所以不是 RCE；但面板连接的是*用户的*服务器，
          # 连接参数应该完全由用户在 deploy.yml 里声明的内容决定
          # （ssh_options 就是从那里来的），不应该悄悄再叠加一层运维本机、
          # 面板之外的配置——一条 `ProxyCommand`/`HostName` 匹配上目标
          # host 就会在面板不知情的情况下改变连接行为。`false` 而不是
          # `nil`：`nil` 会被下面的 `.compact` 删掉这个键，net-ssh 收不到
          # 这个选项就会退回默认值（读取 ssh config），达不到关闭的效果。
          config: false
        }.compact
      end
  end
end
