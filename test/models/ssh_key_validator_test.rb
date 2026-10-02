require "test_helper"
require "timeout"

# 这组测试把「校验一个提交上来的私钥」当成一次攻击来测：SshKeyValidator
# 之所以存在，是因为 net-ssh 解析私钥时可能触达 OpenSSL/bcrypt，真正的
# 解密/KDF 尝试要花多久由私钥里攻击者可控的字段（bcrypt rounds、PKCS#8
# iteration count）决定，而这条校验发生在未认证的路由上（创建 ManagedApp
# 不需要登录，见 spec 7.2）。
#
# 早先的做法是自己先读一遍私钥 header 判断"是不是带密码"来跳过解析，
# 结果制造了一个「自制 reader 必须和 net-ssh 对同一段字节的理解永远
# 一致」的双重解析器问题——真的出现过 bypass（见下面「每行加 -----前缀」
# 那条测试，就是复现过的那个绕过）。现在的做法不再预判 net-ssh 会做
# 什么，而是把解析放进子进程、由父进程持有硬超时——所以这里的测试断言
# 的是"墙钟时间落在超时范围内"，而不是"解析很快"：前者才是真正验证了
# 超时确实在起作用，而不是恰好这次输入碰巧解析得快。
class SshKeyValidatorTest < ActiveSupport::TestCase
  # 两个测试专用的假子进程，只用来验证 run_subprocess 里"写 stdin 也受硬
  # 超时保护、子进程提前退出不会变成未捕获的 Errno::EPIPE"这两件事本身，
  # 不依赖真实 net-ssh 的任何行为：
  #   - NeverReadsStdin：故意永远不读 stdin（模拟一个卡住的/恶意的子
  #     进程），用来验证父进程的 stdin.write 不会因此卡住整个父进程。
  #   - ExitsImmediately：故意立刻退出、完全不读 stdin，用来验证父进程
  #     的 stdin.write 撞上一个已经关闭的管道时，只会得到 Errno::EPIPE
  #     被安静地吞掉，而不是抛出去变成调用方看到的异常。
  class NeverReadsStdin < SshKeyValidator
    private
      def command
        [ RbConfig.ruby, "-e", "sleep 100" ]
      end
  end

  class ExitsImmediately < SshKeyValidator
    private
      def command
        [ RbConfig.ruby, "-e", "exit 0" ]
      end
  end

  def real_key
    File.read(Rails.root.join("test/fake_host/id_ed25519"))
  end

  # 一把用 `ssh-keygen -N <passphrase>` 生成的真实带密码私钥（默认 16 轮
  # bcrypt）。之所以在测试里硬编码字面量而不是运行 ssh-keygen 生成：测试
  # 要在任何 CI 环境下都能跑，不依赖外部命令。
  def real_encrypted_key
    <<~KEY
      -----BEGIN OPENSSH PRIVATE KEY-----
      b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBtpKcxau
      yj+NdB+hJd1IWFAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIOJPvz4TAssYb/bn
      UlIWbfr/NGKBIr21v5dLeflI4dzvAAAAkGjBap0O+bAxUNFZYQU5KLwruLvrfYv5Ii1hVm
      eXt1kyV8kmdsVHRDFSOJ96POf0vy6gWZedqKa0mPlVhxdwvqWnmlUIKL7VE2E8umlLWbfu
      n+RrLJfcrKng0hyw+lCYarSidsQJ6Y9a/2C+Y7seEW+22hcge9OHx2x/WK//2mLMTVoaMa
      qPZ8XB9TZeTnPq9g==
      -----END OPENSSH PRIVATE KEY-----
    KEY
  end

  test "真实私钥被判定可用，并给出指纹" do
    result = SshKeyValidator.call(real_key)

    assert result.ok?
    refute result.encrypted?
    assert_match(/\ASHA256:/, result.fingerprint)
  end

  test "真实带密码的私钥被判定为 encrypted，且判断很快（默认 16 轮 bcrypt，不是攻击输入）" do
    elapsed = monotonic_seconds { @result = SshKeyValidator.call(real_encrypted_key) }

    refute @result.ok?
    assert @result.encrypted?
    assert_operator elapsed, :<, 1.0
  end

  test "声明未知 key 类型的私钥被判定为不可用，而不是抛异常" do
    result = SshKeyValidator.call(openssh_key(type_name: "ssh-dss"))

    refute result.ok?
    refute result.encrypted?
  end

  test "攻击者构造的超大 bcrypt rounds 私钥在硬超时内被杀掉，而不是真的跑完" do
    # cipher=aes256-ctr / kdf=bcrypt，rounds 是 uint32 最大值：如果真的完整
    # 跑完，需要的时间见下面「真实 bcrypt 单轮耗时」那条测试的推算
    # （约 250 CPU-天）。这里只给 0.3 秒的超时，断言墙钟时间落在这个超时
    # 附近（留出进程创建/被杀的开销余量），而不是断言"很快"——只有前者能
    # 真正证明是超时杀掉了子进程，而不是这次输入碰巧解析得快。
    hostile = openssh_key(
      cipher: "aes256-ctr",
      kdf: "bcrypt",
      kdfopts: bcrypt_kdfopts(rounds: 0xFFFFFFFF),
      type_name: "ssh-dss"
    )

    elapsed = monotonic_seconds { with_safety_net { @result = SshKeyValidator.call(hostile, timeout: 0.3) } }

    refute @result.ok?
    assert_equal "timed_out", @result.error_class
    assert_operator elapsed, :<, 2.0, "应该在超时附近被杀掉，而不是真的跑完"
    assert_operator elapsed, :>=, 0.3
  end

  test "同一个超大 rounds 攻击，换成每行加 -----前缀的编码，依然在硬超时内被杀掉" do
    # 这正是复现过的真实绕过：自制的 OpenSSH header reader 按行过滤掉
    # "-----" 开头的行，对这份输入会看到空 body、误判"不是 OpenSSH 私钥"
    # 从而放行；而 net-ssh 内部按固定偏移切片、用宽松的 `unpack1("m")`
    # （忽略非 base64 字符，包括 "-"）解码，两者看到的是完全相同的解码结果
    # （用 base64 body 逐行加前缀，`unpack1("m")` 会原样跳过 "-" 字符）。
    # 现在不再有"自制 reader"这一层，唯一的防线是子进程超时，所以这份
    # 畸形编码不应该比上面那条测试表现出任何差异。
    hostile = openssh_key(
      cipher: "aes256-ctr",
      kdf: "bcrypt",
      kdfopts: bcrypt_kdfopts(rounds: 0xFFFFFFFF),
      type_name: "ssh-dss"
    )
    dashed = hostile.lines.map { |l|
      (l.start_with?("-----BEGIN") || l.start_with?("-----END")) ? l : "-----#{l.chomp}\n"
    }.join

    elapsed = monotonic_seconds { with_safety_net { @result = SshKeyValidator.call(dashed, timeout: 0.3) } }

    refute @result.ok?
    assert_equal "timed_out", @result.error_class
    assert_operator elapsed, :<, 2.0, "每行加 -----前缀不应该绕过硬超时"
  end

  test "攻击者构造的超大 iteration 的 PKCS#8 私钥在硬超时内被杀掉" do
    hostile = hostile_pkcs8(iterations: 200_000_000)

    elapsed = monotonic_seconds { with_safety_net { @result = SshKeyValidator.call(hostile, timeout: 0.3) } }

    refute @result.ok?
    assert_equal "timed_out", @result.error_class
    assert_operator elapsed, :<, 2.0, "应该在超时附近被杀掉，而不是真的跑完 PBKDF2"
  end

  test "真实 bcrypt 单轮耗时（用来对照上面两条测试确实没有真的跑完 KDF）" do
    require "bcrypt_pbkdf"
    elapsed = monotonic_seconds { BCryptPbkdf.key("x", "saltsaltsaltsalt", 48, 100) }
    per_round = elapsed / 100

    # 4294967295 轮 * 每轮耗时，应该远超过上面两条超时测试允许的 2 秒——
    # 也就是说，如果没有硬超时，上面那两条测试会挂很久很久（约 250 CPU-天），
    # 而不是在 2 秒内返回。
    assert_operator per_round * 4_294_967_295, :>, 3600 * 24, "真实 KDF 應该比超时门槛慢好几个数量级"
  end

  test "畸形编码不会造成假拒绝：真实私钥换成不同的换行宽度/首尾空白依然能通过" do
    variants = {
      "无结尾换行" => real_key.chomp,
      "首尾多余空白" => "\n\n  #{real_key}  \n\n",
      "不规则换行宽度（每 40 字符换一行）" => rewrap(real_key, 40)
    }

    variants.each do |label, variant|
      result = SshKeyValidator.call(variant)
      assert result.ok?, "#{label}：应该仍然被判定为可用的私钥，实际 encrypted=#{result.encrypted?}"
    end
  end

  test "CRLF 行结尾的私钥被干净拒绝——这是 net-ssh 自身的行为（它的 BEGIN 标记严格匹配 \\n），不是本类引入的假拒绝" do
    result = SshKeyValidator.call(real_key.gsub("\n", "\r\n"))

    refute result.ok?
    refute result.encrypted?
  end

  # 用来撑满管道缓冲区的 payload：16 KiB 的私钥内容编码成 JSON 之后是
  # 98,316 字节（复现 round 3 review 报告的量级），远超常见的 64KiB
  # 管道缓冲区。
  def huge_value
    "\x01" * (16 * 1024)
  end

  test "父进程写 stdin 也受硬超时保护：子进程从不读 stdin 时，父进程不会被写操作卡住" do
    validator = NeverReadsStdin.new(huge_value, 0.5)

    elapsed = monotonic_seconds { with_safety_net { @result = validator.call } }

    refute @result.ok?
    assert_equal "timed_out", @result.error_class
    # 没有这个修复之前，这里量出来的是 117.85 秒（父进程真的卡在
    # stdin.write 上，硬超时从没生效）。现在应该落在超时附近。
    assert_operator elapsed, :<, 5.0, "stdin.write 应该跟别的 IO 一样受硬超时保护，不应该让父进程卡住"
  end

  test "子进程提前退出（完全不读 stdin）时，父进程写 stdin 不会抛出未处理的 Errno::EPIPE" do
    validator = ExitsImmediately.new(huge_value, 3.0)

    result = nil
    assert_nothing_raised do
      result = validator.call
    end

    refute result.ok?
  end

  test "校验结果不会把子进程内部的异常信息透出" do
    poison = openssh_key(type_name: "ssh-attacker-poison-marker")

    result = SshKeyValidator.call(poison)

    refute result.ok?
    # error_class 只应该是一个类名，不应该包含被拒绝的原始字节
    refute_includes result.error_class.to_s, "poison-marker"
  end

  private
    def monotonic_seconds
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    end

    # 只是给测试本身兜底：如果本类的硬超时哪天真的被改坏了，这里应该让
    # 测试很快报错退出，而不是把整个测试进程（乃至 CI）挂在一次几百年
    # 的 bcrypt 计算上。之所以现在能指望 Timeout.timeout 管用：本轮之前，
    # 父进程会同步阻塞在裸的 `stdin.write` 系统调用上，那种阻塞不会命中
    # Ruby 能安全打断线程的检查点，外层 Timeout.timeout 拦不住（这正是
    # round 3 review 报告里 117.85 秒、连 Timeout.timeout(12) 都拦不住的
    # 那次实测）。现在写 stdin 也在线程里，父进程唯一还会等待的是
    # wait_thread.join(timeout)——一次 Thread#join，是可以被安全打断的。
    def with_safety_net(seconds = 5)
      Timeout.timeout(seconds) { yield }
    rescue Timeout::Error
      flunk "硬超时看起来失效了：这次调用没有在 #{seconds} 秒安全网内返回"
    end

    def rewrap(pem, width)
      lines = pem.lines.map(&:chomp)
      head = lines.first
      tail = lines.last
      body = lines[1..-2].join
      wrapped = body.scan(/.{1,#{width}}/).join("\n")
      "#{head}\n#{wrapped}\n#{tail}\n"
    end

    def ssh_string(bytes)
      [ bytes.bytesize ].pack("N") + bytes
    end

    def bcrypt_kdfopts(rounds:)
      ssh_string("saltsaltsaltsalt") + [ rounds ].pack("N")
    end

    # 构造一个符合 openssh-key-v1 二进制格式的私钥字符串，用来把「解析这个
    # 输入会不会出问题」当作攻击面来测，而不依赖 ssh-keygen（这样测试在
    # 任何 CI 环境下都能跑，也能表达 ssh-keygen 永远不会生成、但攻击者可以
    # 随手构造的字段组合）。
    def openssh_key(cipher: "none", kdf: "none", kdfopts: "", type_name: "ssh-dss", blocksize: 16)
      magic = "openssh-key-v1\0"
      check = "\x01\x02\x03\x04"
      fixed = check + check + ssh_string(type_name)

      # 私钥区块长度必须是 cipher 分组大小的整数倍（net-ssh 在解密前会做
      # 这个检查），否则解析会在到达 KDF 之前就已经因为长度不对被拒绝——
      # 那样就测不到我们真正想测的东西（KDF 有没有真的被跑）。
      pad = (-fixed.bytesize) % blocksize
      pad = blocksize if pad.zero?
      privsection = fixed + ("\x00" * pad)

      body = +""
      body << ssh_string(cipher)
      body << ssh_string(kdf)
      body << ssh_string(kdfopts)
      body << [ 1 ].pack("N")
      body << ssh_string("")
      body << ssh_string(privsection)

      raw = magic + body
      b64 = [ raw ].pack("m0").scan(/.{1,70}/).join("\n")
      "-----BEGIN OPENSSH PRIVATE KEY-----\n#{b64}\n-----END OPENSSH PRIVATE KEY-----\n"
    end

    # 构造一个 PKCS#8 EncryptedPrivateKeyInfo（PBES2 + PBKDF2），iteration
    # count 可以随意设置——这是 openssl/net-ssh 走的另一条解析分支（不是
    # OpenSSH 私钥格式），同一形状的漏洞（攻击者控制 KDF 的"贵不贵"）在这
    # 条分支上也存在，且不受上面 OpenSSH 相关的任何逻辑影响。
    def hostile_pkcs8(iterations:, garbage_len: 64)
      salt = "S" * 16
      pbkdf2_params = OpenSSL::ASN1::Sequence([
        OpenSSL::ASN1::OctetString(salt),
        OpenSSL::ASN1::Integer(iterations)
      ])
      kdf_alg = OpenSSL::ASN1::Sequence([
        OpenSSL::ASN1::ObjectId("1.2.840.113549.1.5.12"), # pbkdf2
        pbkdf2_params
      ])
      iv = "I" * 16
      enc_scheme = OpenSSL::ASN1::Sequence([
        OpenSSL::ASN1::ObjectId("2.16.840.1.101.3.4.1.42"), # aes256-CBC
        OpenSSL::ASN1::OctetString(iv)
      ])
      pbes2_params = OpenSSL::ASN1::Sequence([ kdf_alg, enc_scheme ])
      enc_alg = OpenSSL::ASN1::Sequence([
        OpenSSL::ASN1::ObjectId("1.2.840.113549.1.5.13"), # pbes2
        pbes2_params
      ])
      encrypted_data = OpenSSL::ASN1::OctetString("G" * garbage_len)
      top = OpenSSL::ASN1::Sequence([ enc_alg, encrypted_data ])

      b64 = [ top.to_der ].pack("m0").scan(/.{1,64}/).join("\n")
      "-----BEGIN ENCRYPTED PRIVATE KEY-----\n#{b64}\n-----END ENCRYPTED PRIVATE KEY-----\n"
    end
end
