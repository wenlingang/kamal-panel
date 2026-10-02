require "test_helper"

class CredentialTest < ActiveSupport::TestCase
  def key
    File.read(Rails.root.join("test/fake_host/id_ed25519"))
  end

  test "私钥在数据库中是密文" do
    credential = Credential.create!(kind: "ssh_key", value: key, name: "私钥在数据库中是密文")

    raw = Credential.connection.select_value(
      "SELECT value FROM credentials WHERE id = #{credential.id}"
    )

    refute_includes raw.to_s, "PRIVATE KEY"
    assert_equal key, credential.reload.value
  end

  test "指纹可安全展示，且不含私钥内容" do
    credential = Credential.create!(kind: "ssh_key", value: key, name: "指纹可安全展示")

    assert_match(/\ASHA256:/, credential.fingerprint)
    refute_includes credential.fingerprint, "PRIVATE KEY"
  end

  test "拒绝不像私钥的内容" do
    credential = Credential.new(kind: "ssh_key", value: "hello", name: "拒绝不像私钥的内容")

    refute credential.valid?
  end

  # --- 下面这组测试把「校验一个提交上来的私钥」当成一次攻击来测，而不是
  # happy path：value 目前是在未认证的路由上被校验的（创建 ManagedApp 不
  # 需要登录），提交者可以是任何人，字节可以是精心构造的。对 net-ssh 解析
  # 行为本身的攻击面测试（畸形编码、超大 KDF 参数、硬超时）在
  # test/models/ssh_key_validator_test.rb 里；这里只测 Credential 这一层
  # 自己的职责：把 SshKeyValidator 的结果正确翻译成校验错误、正确记忆化、
  # 不泄露原始字节。-------------------------------------------------------

  test "声明未知 key 类型的私钥被干净拒绝，而不是变成一次异常/500" do
    credential = Credential.new(kind: "ssh_key", value: openssh_key(type_name: "ssh-dss"),
                                 name: "声明未知 key 类型的私钥")

    refute credential.valid?
    assert_includes credential.errors[:value].join, "不是可用的 SSH 私钥"
  end

  test "超过大小上限的私钥在被解析之前就被拒绝（不会触发子进程）" do
    oversized = "-----BEGIN OPENSSH PRIVATE KEY-----\n" +
                ("A" * (Credential::MAX_VALUE_BYTES + 1)) +
                "\n-----END OPENSSH PRIVATE KEY-----"
    credential = Credential.new(kind: "ssh_key", value: oversized, name: "超过大小上限的私钥")

    called = false
    original = SshKeyValidator.method(:call)
    SshKeyValidator.define_singleton_method(:call) do |*args, **kwargs|
      called = true
      original.call(*args, **kwargs)
    end

    begin
      refute credential.valid?
    ensure
      SshKeyValidator.define_singleton_method(:call, original)
    end

    assert_includes credential.errors[:value].join, "过长"
    refute called, "超过大小上限应该在调用 SshKeyValidator 之前就被拒绝"
  end

  test "畸形私钥的错误信息里不包含任何提交的原始字节" do
    poison = openssh_key(type_name: "ssh-attacker-poison-marker")
    credential = Credential.new(kind: "ssh_key", value: poison, name: "畸形私钥")

    refute credential.valid?
    refute_includes credential.errors.full_messages.join, "poison-marker"
    refute_includes credential.errors.full_messages.join, poison
  end

  test "fingerprint 在保存时算好存进列，读取时不再触发子进程" do
    credential = Credential.create!(kind: "ssh_key", value: key, name: "fingerprint 保存时算好")

    called = false
    original = SshKeyValidator.method(:call)
    SshKeyValidator.define_singleton_method(:call) do |*args, **kwargs|
      called = true
      original.call(*args, **kwargs)
    end

    fresh = Credential.find(credential.id) # 全新实例，没有任何记忆化状态
    fingerprint = nil
    begin
      fingerprint = fresh.fingerprint
    ensure
      SshKeyValidator.define_singleton_method(:call, original)
    end

    assert_match(/\ASHA256:/, fingerprint)
    refute called, "fingerprint 已经在保存时算好、存进列了，读取不应该再调用 SshKeyValidator"
  end

  test "fingerprint 列在这条记录存在之前就是空的（旧记录）时，读取会现算一次并回填，而不是报错" do
    credential = Credential.create!(kind: "ssh_key", value: key, name: "fingerprint 列曾经为空")
    credential.update_column(:fingerprint, nil) # 模拟这一列加上去之前就存在的旧记录

    fresh = Credential.find(credential.id)
    assert_nil fresh.read_attribute(:fingerprint)

    fingerprint = fresh.fingerprint
    assert_match(/\ASHA256:/, fingerprint)

    # 回填之后，这一行就该跟正常保存的记录没区别——下一次读，列里已经有值了。
    assert_equal fingerprint, Credential.find(credential.id).read_attribute(:fingerprint)
  end

  test "同一个实例里，校验和 fingerprint 共享同一次子进程校验结果（不会重复解析）" do
    credential = Credential.new(kind: "ssh_key", value: key, name: "共享同一次校验结果")
    calls = 0
    original = SshKeyValidator.method(:call)

    SshKeyValidator.define_singleton_method(:call) do |*args, **kwargs|
      calls += 1
      original.call(*args, **kwargs)
    end

    begin
      credential.valid?
      credential.fingerprint
      credential.fingerprint
    ensure
      SshKeyValidator.define_singleton_method(:call, original)
    end

    assert_equal 1, calls, "同一个 value 应该只触发一次子进程校验"
  end

  test "名字必填且唯一" do
    key = FakeHost.private_key

    assert_predicate Credential.new(kind: "ssh_key", value: key), :invalid?

    Credential.create!(kind: "ssh_key", value: key, name: "生产集群")
    dup = Credential.new(kind: "ssh_key", value: key, name: "生产集群")

    refute_predicate dup, :valid?
  end

  # #inspect 已由 Active Record encryption 过滤，但序列化路径不受它管辖。
  # 这条防线此前只在 Credential 上，抽进 concern 之后两种凭据都要有。
  test "序列化时永远不带出 value" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")

    refute_includes credential.to_json, "PRIVATE KEY"
    refute_includes credential.as_json.keys, "value"
  end

  # 共享池里一次删除可以同时搞断好几个应用的采集与部署，而操作的人看不到
  # 任何提示。所以被引用时必须删不掉，不是删完把引用置空。
  test "还被应用引用时删不掉" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                             destination: "production", ssh_credential: credential)

    refute credential.destroy
    assert Credential.exists?(credential.id)
    assert_predicate credential.errors[:base], :present?

    app.update!(ssh_credential: nil)
    assert credential.destroy
  end

  private
    # 构造一个符合 openssh-key-v1 二进制格式的私钥字符串，用于把「解析这个
    # 输入会不会出问题」当作攻击面来测，而不依赖 ssh-keygen 生成真实密钥
    # （这样测试在任何 CI 环境下都能跑，不需要外部命令）。跟
    # SshKeyValidatorTest 里的同名 helper 逻辑一致；这里只需要"能触发一次
    # 真正的解析尝试"，不需要覆盖 KDF/超时相关的场景（那些在
    # SshKeyValidatorTest 里）。
    def openssh_key(type_name:)
      magic = "openssh-key-v1\0"
      check = "\x01\x02\x03\x04"
      fixed = check + check + ssh_string(type_name)
      pad = (-fixed.bytesize) % 16
      pad = 16 if pad.zero?
      privsection = fixed + ("\x00" * pad)

      body = +""
      body << ssh_string("none")
      body << ssh_string("none")
      body << ssh_string("")
      body << [ 1 ].pack("N")
      body << ssh_string("")
      body << ssh_string(privsection)

      raw = magic + body
      b64 = [ raw ].pack("m0").scan(/.{1,70}/).join("\n")
      "-----BEGIN OPENSSH PRIVATE KEY-----\n#{b64}\n-----END OPENSSH PRIVATE KEY-----"
    end

    def ssh_string(bytes)
      [ bytes.bytesize ].pack("N") + bytes
    end
end
