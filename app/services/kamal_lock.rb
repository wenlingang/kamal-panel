# 读 Kamal 自己的部署锁（spec 7.4）。
class KamalLock
  LOCK_PRESENT_MARKER = "KAMAL_PANEL_LOCK_PRESENT"
  LOCK_ABSENT_MARKER  = "KAMAL_PANEL_LOCK_ABSENT"

  def initialize(managed_app)
    @managed_app = managed_app
  end

  def status
    result = session.capture_many([ primary_host ]) { read_command }.fetch(primary_host)

    # 连不上时【绝不报告「未锁定」】：那会让面板放行一次它无权确认的操作。
    return { locked: false, details: nil, error: result.error } if result.error

    # 判定信号只看第一行；payload（锁持有者信息，攻击者可控的自由文本）绝不参与判定。
    # payload 是攻击者可控的自由文本，绝不参与判定——否则含 LOCK_ABSENT 子串的锁消息能骗过它。
    marker, _separator, payload = result.stdout.to_s.partition("\n")

    if marker == LOCK_ABSENT_MARKER
      { locked: false, details: nil, error: nil }
    else
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
      "if [ -d #{dir} ]; then " \
        "echo #{LOCK_PRESENT_MARKER}; " \
        "cat #{dir}/details 2>/dev/null | base64 -d 2>/dev/null; " \
      "else " \
        "echo #{LOCK_ABSENT_MARKER}; " \
      "fi"
    end
end
