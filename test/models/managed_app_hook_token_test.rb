require "test_helper"

class ManagedAppHookTokenTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  test "reports hook reporting as disabled when no token is generated" do
    refute_predicate @app, :hook_reporting_enabled?
    assert_nil ManagedApp.find_by_hook_token("anything")
  end

  test "finds the app by plaintext after generation" do
    token = @app.regenerate_hook_token!

    assert_predicate @app.reload, :hook_reporting_enabled?
    assert_equal @app, ManagedApp.find_by_hook_token(token)
  end

  test "does not persist the plaintext" do
    token = @app.regenerate_hook_token!

    row = ManagedApp.connection.select_one("SELECT * FROM managed_apps WHERE id = #{@app.id}")

    refute_includes row.values.map(&:to_s).join("\n"), token
  end

  test "reset invalidates the old token immediately" do
    old = @app.regenerate_hook_token!
    new = @app.regenerate_hook_token!

    refute_equal old, new
    assert_nil ManagedApp.find_by_hook_token(old)
    assert_equal @app, ManagedApp.find_by_hook_token(new)
  end

  test "an empty token matches no app" do
    @app.regenerate_hook_token!

    assert_nil ManagedApp.find_by_hook_token("")
    assert_nil ManagedApp.find_by_hook_token(nil)
  end

  test "records a rejected report on the app" do
    @app.reject_hook!("收到 service=other 的上报，但这个 token 属于 blog")

    assert_match "service=other", @app.reload.last_hook_rejection
    assert_predicate @app.last_hook_rejection_at, :present?
  end

  test "rotates the token even for an app with a broken config" do
    @app.update_column(:config_yaml, "这不是 yaml: [")
    refute_predicate @app.reload, :valid? # confirm it really is broken, not testing a premise that always passes

    token = nil
    assert_nothing_raised { token = @app.regenerate_hook_token! }
    assert_equal @app, ManagedApp.find_by_hook_token(token)
  end
end
