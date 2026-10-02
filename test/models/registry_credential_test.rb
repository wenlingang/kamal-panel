require "test_helper"

class RegistryCredentialTest < ActiveSupport::TestCase
  test "名字必填且唯一，密码必填" do
    assert_predicate RegistryCredential.new(value: "s3cr3t"), :invalid?
    assert_predicate RegistryCredential.new(name: "Docker Hub"), :invalid?

    RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t")
    refute_predicate RegistryCredential.new(name: "Docker Hub", value: "other"), :valid?
  end

  test "序列化时永远不带出 value" do
    credential = RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t")

    refute_includes credential.to_json, "s3cr3t"
    refute_includes credential.as_json.keys, "value"
  end

  test "密码是加密存的" do
    RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t")

    raw = RegistryCredential.connection.select_value("SELECT value FROM registry_credentials LIMIT 1")
    refute_includes raw.to_s, "s3cr3t"
  end

  # server 只用来在选凭据时提示"这条像是给别的 registry 用的"，所以可空：
  # deploy.yml 里本来就有 server，面板不需要它才能工作。
  test "server 可以留空" do
    assert_predicate RegistryCredential.new(name: "Docker Hub", value: "s3cr3t"), :valid?
  end

  # dotenv 的单引号值对单引号和换行都没有可用的转义，所以这两个字符在保存
  # 时就得被拦住——否则面板拼出的那一行会从中间断开，把后面的字节交给
  # dotenv 当成别的变量。
  test "密码里带单引号会被拒" do
    credential = RegistryCredential.new(name: "Docker Hub", value: "s3c'r3t")

    refute_predicate credential, :valid?
    assert_includes credential.errors[:value].join, "单引号"
  end

  test "密码里带换行会被拒" do
    refute_predicate RegistryCredential.new(name: "Docker Hub", value: "s3cr3t\nMORE=x"), :valid?
    refute_predicate RegistryCredential.new(name: "Docker Hub", value: "s3cr3t\rMORE=x"), :valid?
  end

  test "dotenv 会做手脚的那些字符本身是允许的——它们由写文件那一侧加引号解决" do
    tricky = "p@ss#word $(id) $HOME back\\slash "

    assert_predicate RegistryCredential.new(name: "Docker Hub", value: tricky), :valid?
  end

  test "还被应用引用时删不掉" do
    credential = RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t")
    app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                             destination: "production", registry_credential: credential)

    refute credential.destroy
    assert RegistryCredential.exists?(credential.id)

    app.update!(registry_credential: nil)
    assert credential.destroy
  end
end
