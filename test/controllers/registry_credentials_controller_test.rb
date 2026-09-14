require "test_helper"

class RegistryCredentialsControllerTest < ActionDispatch::IntegrationTest
  # 一个好认的字面量：出现在 HTML 里一眼能看出来是泄漏，不会和别的字节撞上。
  SECRET = "绝密registry密码-Zk7q".freeze
  OTHER_SECRET = "另一个绝密registry密码-Mx2v".freeze

  test "非 admin 一个动作都进不去" do
    credential = RegistryCredential.create!(name: "Docker Hub", value: SECRET,
                                            server: "registry.example.com")
    sign_in_as users(:three)

    get new_registry_credential_path
    assert_redirected_to root_path

    assert_no_difference -> { RegistryCredential.count } do
      post registry_credentials_path, params: { registry_credential: { name: "偷渡", value: "x" } }
    end
    assert_redirected_to root_path

    get edit_registry_credential_path(credential)
    assert_redirected_to root_path

    patch registry_credential_path(credential),
          params: { registry_credential: { value: OTHER_SECRET } }
    assert_redirected_to root_path
    assert_equal SECRET, credential.reload.value

    assert_no_difference -> { RegistryCredential.count } do
      delete registry_credential_path(credential)
    end
    assert_redirected_to root_path
  end

  test "admin 新建并写审计" do
    sign_in_as users(:two)

    assert_difference -> { RegistryCredential.count }, 1 do
      post registry_credentials_path,
           params: { registry_credential: { name: "Docker Hub", value: "s3cr3t", server: "registry.example.com" } }
    end

    assert_equal "Docker Hub", AuditLog.where(action_name: "registry_credential.create").sole.detail
  end

  # 凭据只写不读：表单页任何时候都不能把密码明文渲染回 HTML。
  test "新建页与替换页都不回显密码明文" do
    credential = RegistryCredential.create!(name: "Docker Hub", value: SECRET,
                                            server: "registry.example.com")
    sign_in_as users(:two)

    get new_registry_credential_path
    assert_response :success
    refute_includes @response.body, SECRET

    get edit_registry_credential_path(credential)
    assert_response :success
    refute_includes @response.body, SECRET
  end

  test "创建失败重渲表单时也不回显密码明文" do
    RegistryCredential.create!(name: "Docker Hub", value: SECRET)
    sign_in_as users(:two)

    # 重名，创建必失败，走 render :new 那条重渲路径。
    post registry_credentials_path,
         params: { registry_credential: { name: "Docker Hub", value: SECRET } }

    assert_response :unprocessable_entity
    refute_includes @response.body, SECRET
  end

  test "列表页不含密码明文" do
    RegistryCredential.create!(name: "Docker Hub", value: SECRET, server: "registry.example.com")
    sign_in_as users(:two)

    get credentials_path

    assert_response :success
    refute_includes @response.body, SECRET
  end

  def value_digest(record) = Digest::SHA256.hexdigest(record.value)

  test "轮换真的换掉了 value，名字不变，并写审计" do
    credential = RegistryCredential.create!(name: "Docker Hub", value: SECRET,
                                            server: "registry.example.com")
    digest_before = value_digest(credential)
    sign_in_as users(:two)

    patch registry_credential_path(credential),
          params: { registry_credential: { value: OTHER_SECRET } }

    credential.reload
    assert_equal "Docker Hub", credential.name
    refute_equal digest_before, value_digest(credential)
    assert_equal "Docker Hub", AuditLog.where(action_name: "registry_credential.rotate").sole.detail
  end

  test "没被引用的凭据可以删，并写审计" do
    credential = RegistryCredential.create!(name: "闲置的", value: SECRET)
    sign_in_as users(:two)

    delete registry_credential_path(credential)

    refute RegistryCredential.exists?(credential.id)
    assert_equal "闲置的", AuditLog.where(action_name: "registry_credential.delete").sole.detail
  end

  # 被引用时那条提示是这一页唯一会教人做事的文案，所以它说的必须是面板真能做到
  # 的事：面板没有给已接入的应用改凭据的入口，能做的只有替换这条凭据的内容。
  test "被引用的凭据删不掉，提示点名了是哪个应用、也只让人做做得到的事" do
    credential = RegistryCredential.create!(name: "Docker Hub", value: SECRET)
    ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                       destination: "production", registry_credential: credential)
    sign_in_as users(:two)

    delete registry_credential_path(credential)

    assert_redirected_to credentials_path
    assert_includes flash[:alert], "Docker Hub"
    assert_includes flash[:alert], "blog"
    assert_includes flash[:alert], edit_registry_credential_path(credential)
    refute_includes flash[:alert], "换成别的凭据"
    assert RegistryCredential.exists?(credential.id)
    assert_equal 0, AuditLog.where(action_name: "registry_credential.delete").count
  end
end
