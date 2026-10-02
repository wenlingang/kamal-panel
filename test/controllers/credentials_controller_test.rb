require "test_helper"

class CredentialsControllerTest < ActionDispatch::IntegrationTest
  # 注意：这个文件里【不要】把 ManagedApp 存进 @app——在
  # ActionDispatch::IntegrationTest 里 @app 会覆盖 Runner#app，所有 *_path
  # 辅助方法会整体消失，报错看起来像路由没定义。
  setup do
    @managed_app = ManagedApp.create!(name: "blog",
                                      config_yaml: file_fixture("simple_deploy.yml").read,
                                      destination: "production")
  end

  # 轮换要换成【另一把】钥匙才说明得了问题：用同一把钥匙替换自己的话，
  # 哪怕 update 什么都没写，断言一样会绿。生成一次，整个文件复用——
  # 2048 位密钥生成不便宜。
  def self.other_private_key
    @other_private_key ||= OpenSSL::PKey::RSA.generate(2048).to_pem
  end

  def other_private_key = self.class.other_private_key

  # 断言"明文变了"时比较的是摘要而不是明文：断言失败时 minitest 会把两边
  # 都打印出来，比较明文等于把私钥打进测试输出。
  def value_digest(record) = Digest::SHA256.hexdigest(record.value)

  test "非 admin 一个动作都进不去" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    digest_before = value_digest(credential)

    [ users(:one), users(:three) ].each do |user|
      sign_in_as user

      get credentials_path
      assert_redirected_to root_path

      get new_credential_path
      assert_redirected_to root_path

      assert_no_difference -> { Credential.count } do
        post credentials_path, params: { credential: { name: "偷渡", value: FakeHost.private_key } }
      end
      assert_redirected_to root_path

      get edit_credential_path(credential)
      assert_redirected_to root_path

      patch credential_path(credential), params: { credential: { value: other_private_key } }
      assert_redirected_to root_path
      assert_equal digest_before, value_digest(credential.reload)

      assert_no_difference -> { Credential.count } do
        delete credential_path(credential)
      end
      assert_redirected_to root_path

      sign_out
    end
  end

  test "admin 看得到列表，以及每条正被哪些应用引用" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    @managed_app.update!(ssh_credential: credential)
    sign_in_as users(:two)

    get credentials_path

    assert_response :success
    assert_select "td", text: /生产集群/
    assert_select "td", text: /blog/
  end

  # 凭据只写不读。这三条守的是同一件事：表单页【任何时候】都不能把私钥
  # 明文渲染回 HTML。删掉视图里的 `value: nil` 这三条就会红——form.text_area
  # 默认会把已持久化记录的当前值当成标签体渲染出来。
  test "列表页不含私钥明文" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    @managed_app.update!(ssh_credential: credential)
    sign_in_as users(:two)

    get credentials_path

    assert_response :success
    refute_includes @response.body, FakeHost.private_key
  end

  test "新建页与替换页都不回显私钥明文" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    sign_in_as users(:two)

    get new_credential_path
    assert_response :success
    refute_includes @response.body, FakeHost.private_key

    get edit_credential_path(credential)
    assert_response :success
    refute_includes @response.body, FakeHost.private_key
  end

  test "创建失败重渲表单时也不回显私钥明文" do
    Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    sign_in_as users(:two)

    # 重名，创建必失败，走 render :new 那条重渲路径。
    post credentials_path, params: { credential: { name: "生产集群", value: FakeHost.private_key } }

    assert_response :unprocessable_entity
    refute_includes @response.body, FakeHost.private_key
  end

  test "新建写审计，且审计里记得住是哪条凭据" do
    sign_in_as users(:two)

    assert_difference -> { Credential.count }, 1 do
      post credentials_path, params: { credential: { name: "生产集群", value: FakeHost.private_key } }
    end

    log = AuditLog.where(action_name: "credential.create").sole
    assert_equal "生产集群", log.detail
    assert_nil log.managed_app
  end

  test "轮换真的换掉了 value，名字不变，并写审计" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    digest_before = value_digest(credential)
    sign_in_as users(:two)

    patch credential_path(credential), params: { credential: { value: other_private_key } }

    credential.reload
    assert_equal "生产集群", credential.name
    refute_equal digest_before, value_digest(credential)
    assert_equal 1, AuditLog.where(action_name: "credential.rotate").count
  end

  test "被引用的凭据删不掉，页面给出理由" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    @managed_app.update!(ssh_credential: credential)
    sign_in_as users(:two)

    delete credential_path(credential)

    assert_redirected_to credentials_path
    # 这句话是这条路径上唯一告诉人"接下来要去改哪几个应用"的东西，
    # 所以它必须点名那个应用。
    assert_includes flash[:alert], "生产集群"
    assert_includes flash[:alert], "blog"
    # 面板没有给已接入的应用改凭据的入口（routes 里 managed_apps 没有 update），
    # 所以这句提示只能指向"替换这条凭据的内容"这条真走得通的路。
    assert_includes flash[:alert], edit_credential_path(credential)
    refute_includes flash[:alert], "换成别的凭据"
    assert Credential.exists?(credential.id)
    assert_equal 0, AuditLog.where(action_name: "credential.delete").count
  end

  test "没被引用的凭据可以删，并写审计" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "闲置的")
    sign_in_as users(:two)

    delete credential_path(credential)

    refute Credential.exists?(credential.id)
    assert_equal "闲置的", AuditLog.where(action_name: "credential.delete").sole.detail
  end
end
