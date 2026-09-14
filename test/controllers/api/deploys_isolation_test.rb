require "test_helper"

# 上报字段与写操作参数完全隔离：动作的 cli_args 由封闭动作集自己生成。
# 这条要显式钉住，而不是靠"我知道它们没连着"。
class Api::DeploysIsolationTest < ActionDispatch::IntegrationTest
  setup do
    @managed_app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    @token = @managed_app.regenerate_hook_token!
  end

  test "带 shell 元字符的 version 直接被拒，不落库" do
    [ "a; rm -rf /", "$(whoami)", "`id`", "../../etc/passwd", "a b" ].each do |bad|
      post "/api/deploys",
           params: { phase: "succeeded", service: "blog", destination: "production",
                     version: bad, performer: "ci", command: "deploy" },
           headers: { "Authorization" => "Bearer #{@token}" }

      assert_response :unprocessable_entity, "#{bad.inspect} 不该被接受"
    end

    assert_equal 0, DeployEvent.count
  end

  test "上报里的 version 不会进入任何动作的 cli_args" do
    post "/api/deploys",
         params: { phase: "succeeded", service: "blog", destination: "production",
                   version: "aaaaaaa", performer: "ci", command: "deploy" },
         headers: { "Authorization" => "Bearer #{@token}" }
    assert_response :no_content

    # 动作的版本号来自调用方显式传入的 target_version，与上报无关
    args = Actions::Restart.new(@managed_app, target_version: "bbbbbbb").cli_args

    assert_includes args, "bbbbbbb"
    refute_includes args.join(" "), "aaaaaaa"
  end
end
