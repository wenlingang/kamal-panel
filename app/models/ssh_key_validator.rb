require "open3"
require "json"

# 在受限子进程中解析候选 SSH 私钥，带硬超时。
#
# 复用 Kamal::ConfigParser 解析 deploy.yml 已经验证过的边界形状：不可信
# 输入（这里是任何人都能通过创建 ManagedApp 提交的字节，见 spec 7.2——这条
# 路由在认证功能上线之前是未认证的）交给真正的第三方解析器（net-ssh），在
# 独立子进程里跑；父进程持有硬超时，子进程无论做了什么、花了多久，超时了
# 就直接 SIGKILL。
#
# 这里不是"照抄"，而是刻意地只搬这一部分：ConfigParser 额外用了一个由
# 父进程持有、子进程只读的临时目录，那是因为 Kamal::Configuration
# .create_from 要求的是文件路径，且要满足 destination 伴随文件的约定。
# net-ssh 的 Net::SSH::KeyFactory.load_data_private_key 直接接受字符串，
# 不需要文件路径——而私钥是需要格外小心的秘密材料，能不落盘就不落盘更安全，
# 所以这里改用 stdin/stdout 直接传递字节，父子进程全程不创建任何临时文件。
#
# 为什么不在调用子进程之前，自己先解析一遍私钥 header 来判断"是不是带
# 密码"从而跳过整个子进程：真的尝试过，结果是制造了一个"自制 reader 和
# net-ssh 必须对同一段字节达成一致"的双重解析器问题，而两者对畸形输入
# （比如每行都加 "-----" 前缀）的理解并不一致，出现过一次真实的 bypass。
# 所以这里彻底不做任何预判——bin/validate_ssh_key 里就是老老实实调用
# net-ssh，本类只负责“给它一个硬超时”。
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

    # 子进程命令。抽成方法（而不是内联在 run_subprocess 里）只是为了让
    # 测试能在子类里覆写它，换成一个故意不读 stdin / 故意立刻退出的假子
    # 进程，从而在不依赖真实 net-ssh 行为的前提下，验证下面 run_subprocess
    # 里的超时/EPIPE 处理本身是对的。生产路径永远是这一份。
    def command
      [ RbConfig.ruby, SCRIPT ]
    end

    # 返回 [stdout, timed_out]。
    def run_subprocess
      input = JSON.generate(value: value)
      stdout = nil
      timed_out = false

      Open3.popen3(*command) do |stdin, out, err, wait_thread|
        # 写 stdin、读 stdout、读 stderr 三件事都必须放进各自的线程，且都
        # 必须在 wait_thread.join 之前就启动——三者都可能阻塞父进程：
        #
        #   写：如果 payload 超过操作系统的管道缓冲区（常见 64KiB）而子
        #   进程还没开始读，同步的 stdin.write 会阻塞父进程，而这个阻塞
        #   发生在 wait_thread.join(timeout) 生效之前，完全不受硬超时
        #   保护——这正是本方法这一轮要修的问题：16 KiB 的私钥编码成
        #   JSON 之后能轻松压满缓冲区；对一个从不读 stdin 的子进程，父
        #   进程曾经在 stdin.write 上真实阻塞了 117.85 秒，外层再包一层
        #   Timeout.timeout 都拦不住（因为阻塞的线程从没运行到能被安全
        #   打断的地方）；对一个提前退出的子进程，父进程的 stdin.write
        #   会直接抛出未被捕获的 Errno::EPIPE，变成调用方看到的一次 500。
        #
        #   读：子进程写出的内容超过缓冲区时，只在 join 之后才读会造成
        #   等价的阻塞（原因见 Kamal::ConfigParser 里同名注释）。
        #
        # 子进程提前退出或者从不读 stdin，都是正常结局（不是我们要抛给
        # 调用方的异常），所以这里只 rescue Errno::EPIPE，不吞别的错误。
        stdin_writer = Thread.new do
          stdin.write(input)
        rescue Errno::EPIPE
          nil
        ensure
          stdin.close
        end

        # 子进程被 SIGKILL/超时打断时，读线程会在半途的 IO 上撞见
        # IOError（"stream closed"之类），这是预期之内的收尾噪音，不是
        # 需要记录的错误，所以吞掉、不让它的 backtrace 混进日志。
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
