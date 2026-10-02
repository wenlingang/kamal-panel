require "test_helper"

class HookScriptTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    @script = HookScript.new(@app, base_url: "https://panel.example.com", token: "T0KEN")
  end

  test "带 shebang 和各自的文件名注释，chmod +x 之后能直接跑" do
    assert_match(/\A#!\/bin\/sh\n/, @script.pre_deploy)
    assert_match(/\A#!\/bin\/sh\n/, @script.post_deploy)
    assert_match "# .kamal/hooks/pre-deploy", @script.pre_deploy
    assert_match "# .kamal/hooks/post-deploy", @script.post_deploy
  end

  test "两段脚本只差 phase" do
    assert_match "phase=started", @script.pre_deploy
    assert_match "phase=succeeded", @script.post_deploy
  end

  test "面板挂掉不能拖垮用户的部署" do
    [ @script.pre_deploy, @script.post_deploy ].each do |body|
      assert_match "--max-time 5", body
      assert_match "|| true", body
    end
  end

  test "带上端点与 token" do
    assert_match "https://panel.example.com/api/deploys", @script.pre_deploy
    assert_match "Authorization: Bearer T0KEN", @script.pre_deploy
  end

  test "送的是 Kamal 自己的环境变量" do
    %w[KAMAL_SERVICE KAMAL_DESTINATION KAMAL_VERSION KAMAL_PERFORMER
       KAMAL_RECORDED_AT KAMAL_COMMAND].each do |var|
      assert_match var, @script.post_deploy
    end
  end
end
