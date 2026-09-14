# 读 Kamal 自己的部署锁（spec 7.4）。
#
# 锁是 primary host 上的一个目录，details 文件里是 base64 编码的持有者信息。
# 目录名规则来自 Kamal::Commands::Lock#lock_dir：
#   [ "lock", service, destination ].compact.join("-")，位于 config.run_directory
#
# 这是纯读操作。面板执行任何变更前必须获取【同一把锁】，否则会与 CI 里
# 正在跑的 kamal deploy 冲突——在本项目设定的架构下（发布归 CI）这是常态。
class KamalLock
  # "有锁"/"无锁"这两个词本身固定不含 \n，且只在没有别的来源能写入
  # 它们的位置（远程命令的第一行 echo 输出）上使用——见下面 read_command
  # 和 status 里"只取第一行判断"的注释：判定信号绝不能和 details 里的
  # 自由文本共用同一个可被内容改写的通道。
  LOCK_PRESENT_MARKER = "KAMAL_PANEL_LOCK_PRESENT"
  LOCK_ABSENT_MARKER  = "KAMAL_PANEL_LOCK_ABSENT"

  def initialize(managed_app)
    @managed_app = managed_app
  end

  def status
    result = session.capture_many([ primary_host ]) { read_command }.fetch(primary_host)

    # 连不上时【绝不报告「未锁定」】：那会让面板放行一次它无权确认的操作。
    return { locked: false, details: nil, error: result.error } if result.error

    # 判定信号只看第一行，payload（锁的持有者信息，攻击者可控的自由文本，
    # 通过 base64 解码后原样出现在第二行起）绝不参与判定。
    #
    # 之前的实现是 `stdout.include?("LOCK_ABSENT")`——"是否已解锁"和
    # "锁的持有者写了什么"共用同一段文本，一条恰好包含 "LOCK_ABSENT"
    # 这个子串的锁消息（完全是攻击者/协作者能控制的自由文本，见
    # write_lock_details）就会让面板在部署进行中错误地报告「未锁定」，
    # 这正是本任务要防止的坍缩，只是绕过了检测点本身，而不是绕过了
    # SSH 连通性。现在的做法：命令保证"判定标记"作为远程命令输出的
    # 第一行、且只由这条命令自己 echo 出来，后续任何内容（哪怕是
    # 已经写到磁盘上的、攻击者完全可控的 details）都只能出现在第一行
    # 之后——出现得晚，就无法覆盖已经发出的第一行。也不依赖"选一个
    # payload 大概率不会包含的魔法字符串"：payload 里包含什么都不
    # 会影响第一行已经被读到、判定已经做出这件事。
    marker, _separator, payload = result.stdout.to_s.partition("\n")

    if marker == LOCK_ABSENT_MARKER
      { locked: false, details: nil, error: nil }
    else
      # 第一行不是"确认无锁"的标记（无论是 LOCK_PRESENT_MARKER，还是任何
      # 因为远程环境异常而出现的、我们没预料到的输出）都当作"有锁"处理——
      # 和"连不上时不报告未锁定"是同一个原则：不确定的时候，绝不往
      # "允许操作"的方向猜。
      { locked: true, details: payload.strip.presence, error: nil }
    end
  end

  private
    attr_reader :managed_app

    def session = Collectors::SshSession.new(managed_app)

    def primary_host = managed_app.parsed_config.primary_host

    def lock_dir
      name = [ "lock", managed_app.service, managed_app.destination ].compact.join("-")
      ".kamal/#{name}"
    end

    def read_command
      dir = Shellwords.escape(lock_dir)
      # base64 -d 后面也加 2>/dev/null：net-ssh 的 exec! 会把 stdout 和
      # stderr 合并进同一段文本，如果 details 文件内容不是合法的
      # base64（比如被截断、被人手工改坏），base64 -d 自己的报错信息
      # 会混进 payload，面板会把这段噪音当成"锁的持有者信息"显示出来
      # （task-5 review 的 minor：display-only，但仍然是把噪音当成
      # 有意义的内容展示）。
      "if [ -d #{dir} ]; then " \
        "echo #{LOCK_PRESENT_MARKER}; " \
        "cat #{dir}/details 2>/dev/null | base64 -d 2>/dev/null; " \
      "else " \
        "echo #{LOCK_ABSENT_MARKER}; " \
      "fi"
    end
end
