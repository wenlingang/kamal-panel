require "test_helper"

class FilterParameterLoggingTest < ActiveSupport::TestCase
  # 两种凭据的表单都提交 credential[value] / registry_credential[value]。
  # Rails 按子串匹配过滤参数名，:value 不在名单里时 "value" 谁都匹配不上——
  # POST /credentials 与 PATCH /credentials/:id 会把整把 SSH 私钥、整条
  # registry 密码以明文写进 production 日志（production 打到 STDOUT，
  # 也就是直接进容器日志）。这一条曾经真实回归过：凭据还叫
  # ssh_private_key 的年代它是被过滤的，改成 value 之后名单没跟着改。
  #
  # 断言的是【行为】而不是 config.filter_parameters 这个数组的形状：Rails 在
  # 应用完全启动之后会把名单里的符号编译成 Regexp，数组里就不再有 :value 这个
  # 符号了。`assert_includes ..., :value` 这种断言单跑一个文件是绿的、在完整
  # 套件里是红的——它守的其实是执行顺序，不是"私钥不会被打进日志"。
  test "凭据表单提交的密文在日志里被遮蔽，而不是留下明文" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

    filtered = filter.filter("credential" => { "name" => "生产集群", "value" => "-----BEGIN OPENSSH PRIVATE KEY-----" })
    assert_equal "[FILTERED]", filtered["credential"]["value"]
    assert_equal "生产集群", filtered["credential"]["name"], "只该遮蔽密文，不该把整个表单糊掉"

    filtered = filter.filter("registry_credential" => { "name" => "Docker Hub", "value" => "s3cr3t" })
    assert_equal "[FILTERED]", filtered["registry_credential"]["value"]
    assert_equal "Docker Hub", filtered["registry_credential"]["name"]
  end
end
