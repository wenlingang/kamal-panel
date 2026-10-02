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

  test "restart（app boot）在没有 target_version 时拒绝生成命令" do
    action = Actions::Restart.new(build_app, target_version: nil)

    assert_raises(ArgumentError) { action.cli_args }
  end

  test "restart 在有 target_version 时把 --version 显式带上" do
    action = Actions::Restart.new(build_app, target_version: "abc1234")

    assert_equal [ "app", "boot", "--version", "abc1234" ], action.cli_args
  end

  test "rollback 在没有 target_version 时拒绝生成命令" do
    action = Actions::Rollback.new(build_app, target_version: nil)

    assert_raises(ArgumentError) { action.cli_args }
  end

  test "rollback 在有 target_version 时把版本号带上" do
    action = Actions::Rollback.new(build_app, target_version: "abc1234")

    assert_equal [ "rollback", "abc1234" ], action.cli_args
  end

  test "stop/start 不强制要求 target_version（它们不需要真实版本号，只是占位以绕开 Kamal 的锁审计文案）" do
    assert_nothing_raised { Actions::Stop.new(build_app, target_version: nil).cli_args }
    assert_nothing_raised { Actions::Start.new(build_app, target_version: nil).cli_args }
  end
end
