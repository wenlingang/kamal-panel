require "test_helper"

class ManagedAppHookTokenTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  test "未生成时上报未启用" do
    refute_predicate @app, :hook_reporting_enabled?
    assert_nil ManagedApp.find_by_hook_token("anything")
  end

  test "生成后能按明文找回应用" do
    token = @app.regenerate_hook_token!

    assert_predicate @app.reload, :hook_reporting_enabled?
    assert_equal @app, ManagedApp.find_by_hook_token(token)
  end

  test "明文不落库" do
    token = @app.regenerate_hook_token!

    row = ManagedApp.connection.select_one("SELECT * FROM managed_apps WHERE id = #{@app.id}")

    refute_includes row.values.map(&:to_s).join("\n"), token
  end

  test "重置让旧 token 立即失效" do
    old = @app.regenerate_hook_token!
    new = @app.regenerate_hook_token!

    refute_equal old, new
    assert_nil ManagedApp.find_by_hook_token(old)
    assert_equal @app, ManagedApp.find_by_hook_token(new)
  end

  test "空 token 不匹配任何应用" do
    @app.regenerate_hook_token!

    assert_nil ManagedApp.find_by_hook_token("")
    assert_nil ManagedApp.find_by_hook_token(nil)
  end

  test "被拒上报记在应用上" do
    @app.reject_hook!("收到 service=other 的上报，但这个 token 属于 blog")

    assert_match "service=other", @app.reload.last_hook_rejection
    assert_predicate @app.last_hook_rejection_at, :present?
  end

  test "配置已损坏的应用仍能轮换 token" do
    @app.update_column(:config_yaml, "这不是 yaml: [")
    refute_predicate @app.reload, :valid? # 确认真的坏了，不是在测一个总能通过的假设

    token = nil
    assert_nothing_raised { token = @app.regenerate_hook_token! }
    assert_equal @app, ManagedApp.find_by_hook_token(token)
  end
end
