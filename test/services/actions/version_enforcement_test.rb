require "test_helper"

# The panel's temp dir has no git repo (README: the panel never touches source code). Kamal's `app
# boot` and `rollback VERSION` read git as soon as they can't get an explicit version, and error out
# if they can't. This caller obligation used to live only in a comment; here it is pinned as
# behavior that really raises.
class Actions::VersionEnforcementTest < ActiveSupport::TestCase
  def build_app
    ManagedApp.new(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                  destination: "production")
  end

  test "restart (app boot) refuses to build a command without target_version" do
    action = Actions::Restart.new(build_app, target_version: nil)

    assert_raises(ArgumentError) { action.cli_args }
  end

  test "restart passes --version explicitly when target_version is present" do
    action = Actions::Restart.new(build_app, target_version: "abc1234")

    assert_equal [ "app", "boot", "--version", "abc1234" ], action.cli_args
  end

  test "rollback refuses to build a command without target_version" do
    action = Actions::Rollback.new(build_app, target_version: nil)

    assert_raises(ArgumentError) { action.cli_args }
  end

  test "rollback includes the version when target_version is present" do
    action = Actions::Rollback.new(build_app, target_version: "abc1234")

    assert_equal [ "rollback", "abc1234" ], action.cli_args
  end

  test "stop/start do not require target_version (placeholder only, to avoid Kamal's lock audit text)" do
    assert_nothing_raised { Actions::Stop.new(build_app, target_version: nil).cli_args }
    assert_nothing_raised { Actions::Start.new(build_app, target_version: nil).cli_args }
  end
end
