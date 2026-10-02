require "test_helper"

# 顶部导航的「当前位置」标识。之前用的是 current_page?(users_path)，那是
# 整条 URL 的精确比对：一进 /users/new 就不再等于 /users，高亮整个消失，
# 人在子页面里看不出自己身在哪一栏。导航要按【版块】高亮，不是按页面。
class NavigationTest < ActionDispatch::IntegrationTest
  setup do
    @managed_app = ManagedApp.create!(name: "blog",
                                      config_yaml: file_fixture("simple_deploy.yml").read,
                                      destination: "production")
    @credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    sign_in_as users(:two)
  end

  # 只断言"哪一栏亮着"，不断言 class 怎么拼——换个高亮实现不该让这里变红。
  def assert_current_nav(label, path)
    get path
    assert_response :success
    assert_select "nav.chrome-nav a.is-current", count: 1 do |links|
      assert_equal label, links.first.text.strip, "#{path} 应该高亮「#{label}」"
    end
  end

  test "版块首页高亮自己那一栏" do
    assert_current_nav "总览", root_path
    assert_current_nav "应用", managed_apps_path
    assert_current_nav "审计", audit_logs_path
    assert_current_nav "人员", users_path
    assert_current_nav "凭据", credentials_path
  end

  test "应用的子页面仍然高亮「应用」" do
    assert_current_nav "应用", new_managed_app_path
    assert_current_nav "应用", managed_app_path(@managed_app)
    assert_current_nav "应用", edit_managed_app_path(@managed_app)
  end

  test "人员的子页面仍然高亮「人员」" do
    assert_current_nav "人员", new_user_path
    assert_current_nav "人员", edit_user_path(users(:one))
  end

  # 镜像库凭据是另一个控制器，但挂在 /credentials/registry 下，对用户来说
  # 就是「凭据」这一栏里的东西。
  test "凭据的子页面仍然高亮「凭据」" do
    assert_current_nav "凭据", new_credential_path
    assert_current_nav "凭据", edit_credential_path(@credential)
    assert_current_nav "凭据", new_registry_credential_path
  end
end
