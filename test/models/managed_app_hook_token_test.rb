require "test_helper"

class ManagedAppHookTokenTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  test "finds the app by plaintext after generation" do
    token = @app.regenerate_hook_token!

    assert_predicate @app.reload, :hook_reporting_enabled?
    assert_equal @app, ManagedApp.find_by_hook_token(token)
  end

  test "reset invalidates the old token immediately" do
    old = @app.regenerate_hook_token!
    new = @app.regenerate_hook_token!

    refute_equal old, new
    assert_nil ManagedApp.find_by_hook_token(old)
    assert_equal @app, ManagedApp.find_by_hook_token(new)
  end
end
