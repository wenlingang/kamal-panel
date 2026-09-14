require "application_system_test_case"

class ManagedAppOnboardingTest < ApplicationSystemTestCase
  setup do
    # 接入应用是写操作，需要 admin（spec 见 context 里的「创建应用本身就是特权操作」）。
    sign_in_as(User.create!(email_address: "admin@example.com", password: "secret123456", role: "admin"))
  end

  test "粘贴 deploy.yml 后当场看到解析出的角色与主机" do
    visit new_managed_app_path

    fill_in "名称", with: "blog"
    fill_in "Destination（可留空）", with: "production"
    fill_in "deploy.yml 原文", with: file_fixture("simple_deploy.yml").read
    click_on "解析并接入"

    assert_text "已接入 blog"
    assert_text "blog-web-production"
    assert_text "registry.example.com"
  end

  test "不填写 destination 时，详情页展示（无），而不是空字符串" do
    visit new_managed_app_path

    fill_in "名称", with: "blog-no-destination"
    fill_in "deploy.yml 原文", with: file_fixture("simple_deploy.yml").read
    click_on "解析并接入"

    assert_text "已接入 blog"
    assert_text "（无）"
  end

  test "无法解析时留在表单页并说明原因" do
    visit new_managed_app_path

    fill_in "名称", with: "broken"
    fill_in "deploy.yml 原文", with: "不是配置"
    click_on "解析并接入"

    assert_text "无法解析"
  end

  test "配置 SSH 私钥后，详情页只展示指纹，绝不回显私钥" do
    visit new_managed_app_path

    fill_in "名称", with: "blog"
    fill_in "Destination（可留空）", with: "production"
    fill_in "deploy.yml 原文", with: file_fixture("simple_deploy.yml").read
    fill_in "SSH 私钥", with: File.read(Rails.root.join("test/fake_host/id_ed25519"))
    click_on "解析并接入"

    assert_text "已接入 blog"
    assert_match(/\ASHA256:/, find("dd", text: /\ASHA256:/).text)
    assert_no_text "PRIVATE KEY"
  end

  test "SSH 私钥不是合法私钥时，表单重新渲染并说明原因（服务端返回的响应见 ManagedAppsControllerTest）" do
    visit new_managed_app_path

    fill_in "名称", with: "blog"
    fill_in "deploy.yml 原文", with: file_fixture("simple_deploy.yml").read
    fill_in "SSH 私钥", with: "-----BEGIN OPENSSH PRIVATE KEY-----\nnot-a-real-key\n-----END OPENSSH PRIVATE KEY-----"
    click_on "解析并接入"

    assert_text "不是可用的 SSH 私钥"
  end
end
