require "test_helper"

# raise_on_missing_translations 配合 fallbacks = [ :en ] 只拦得住「中英都缺」：
# 缺中文时 i18n 会静默退回英文。所以「有中文没英文」这一类漏翻，只有在 :en
# 下真的把页面渲染一遍才抓得到——这个文件就是干这个的。
#
# 刻意【不】断言页面内容，只断言渲染不抛异常。断言内容等于把每一条文案在两种
# 语言下各写一遍，测试数翻倍而信息量不变；而漏翻会让 t() 直接抛出来，
# assert_response :success 就够了。
class LocaleSmokeTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:two)
    @admin.update!(locale: "en")
    @managed_app = ManagedApp.create!(name: "blog",
                                      config_yaml: file_fixture("simple_deploy.yml").read,
                                      destination: "production")
    @credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key,
                                     name: "生产集群")
    AuditLog.record_access!(user: @admin, action_name: "user.deactivate",
                            target_user: users(:one))
  end

  test "英文下每个已登录页面都渲染得出来" do
    sign_in_as @admin

    [
      root_path,
      managed_apps_path, new_managed_app_path,
      managed_app_path(@managed_app), edit_managed_app_path(@managed_app),
      audit_logs_path,
      users_path, new_user_path, edit_user_path(users(:one)),
      credentials_path, new_credential_path, edit_credential_path(@credential),
      new_registry_credential_path
    ].each do |path|
      get path
      assert_response :success, "#{path} 在 :en 下渲染失败"
    end
  end

  test "英文下未登录页面也渲染得出来" do
    get new_session_path, headers: { "HTTP_ACCEPT_LANGUAGE" => "en" }
    assert_response :success

    get new_password_path, headers: { "HTTP_ACCEPT_LANGUAGE" => "en" }
    assert_response :success

    get edit_password_path(users(:one).password_reset_token),
        headers: { "HTTP_ACCEPT_LANGUAGE" => "en" }
    assert_response :success
  end
end
