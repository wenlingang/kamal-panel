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

  # --- The tests below treat "validating a submitted private key" as an attack rather
  # than the happy path: value is currently validated on an unauthenticated route
  # (creating a ManagedApp doesn't require login), so the submitter can be anyone and the
  # bytes can be carefully crafted. Attack-surface tests for net-ssh's parsing behavior
  # itself (malformed encodings, huge KDF parameters, hard timeout) are in
  # test/models/ssh_key_validator_test.rb; here we only test what the Credential layer
  # itself is responsible for: correctly translating SshKeyValidator's result into
  # validation errors, memoizing correctly, and not leaking the raw bytes.
  # -------------------------------------------------------

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

    fresh = Credential.find(credential.id) # a brand-new instance with no memoized state
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
    credential.update_column(:fingerprint, nil) # simulate an old record that existed before this column was added

    fresh = Credential.find(credential.id)
    assert_nil fresh.read_attribute(:fingerprint)

    fingerprint = fresh.fingerprint
    assert_match(/\ASHA256:/, fingerprint)

    # After the backfill, this row should be no different from a normally saved record -- the next
    # read finds the column already populated.
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

  # #inspect is already filtered by Active Record encryption, but the serialization path
  # is outside its jurisdiction. This defense used to exist only on Credential; after
  # extracting it into a concern, both credential types need it.
  test "序列化时永远不带出 value" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")

    refute_includes credential.to_json, "PRIVATE KEY"
    refute_includes credential.as_json.keys, "value"
  end

  # In a shared pool, one deletion can break the collection and deployment of several apps
  # at once, and the person doing it sees no warning. So when referenced it must be
  # undeletable, rather than deleted with the references nulled out.
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
    # Build a private key string that fits the openssh-key-v1 binary format, to test "does
    # parsing this input cause problems" as an attack surface without relying on ssh-keygen
    # to generate a real key (so the test runs in any CI environment, with no external
    # command). Same logic as the helper of the same name in SshKeyValidatorTest; here we
    # only need to "trigger one real parse attempt", not cover KDF/timeout scenarios
    # (those are in SshKeyValidatorTest).
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
