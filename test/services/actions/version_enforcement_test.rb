require "test_helper"

# 面板的临时目录里没有 git 仓库（README：面板永不接触源码）。Kamal 的
# `app boot` 与 `rollback VERSION` 一旦拿不到显式版本号就会去读 git，
# 读不到就直接报错。这条调用方义务过去只活在注释里；这里把它钉成
# 会真正抛异常的行为。
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
