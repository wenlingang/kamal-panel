require "test_helper"

# The actions added for "operations up front" (spec §5): exact argv, lock/confirm flags, and the
# target check against the app's own parsed config.
class Actions::ExtendedActionsTest < ActiveSupport::TestCase
  def build_app(fixture = "accessory_deploy.yml")
    ManagedApp.new(name: "blog", config_yaml: file_fixture(fixture).read, destination: "production")
  end

  def action(name, **options) = Actions::Base.find(name).new(build_app, **options)

  test "every new action is in the closed registry" do
    %w[maintenance live accessory_restart accessory_reboot proxy_restart prune].each do |name|
      assert Actions::Base.find(name) < Actions::Base
      assert_equal name, Actions::Base.find(name).action_name
    end
  end

  # Kamal writes config.version into the lock it acquires, and without --version that falls back
  # to git, which the panel's temp dir does not have. So every locked command carries one.
  test "maintenance / live / proxy restart / prune build their argv with an explicit version" do
    assert_equal [ "app", "maintenance", "--version", "v1" ], action("maintenance", target_version: "v1").cli_args
    assert_equal [ "app", "live", "--version", "v1" ], action("live", target_version: "v1").cli_args
    assert_equal [ "proxy", "restart", "--version", "v1" ], action("proxy_restart", target_version: "v1").cli_args
    assert_equal [ "prune", "all", "--version", "v1" ], action("prune", target_version: "v1").cli_args
  end

  test "without a version, a placeholder still keeps Kamal away from git" do
    args = action("prune").cli_args

    assert_equal [ "prune", "all", "--version" ], args.first(3)
    assert_match(/\Apanel-\h{8}\z/, args.last)
  end

  test "accessory actions name the accessory as Kamal's positional argument" do
    assert_equal [ "accessory", "restart", "db", "--version", "v1" ],
                 action("accessory_restart", target: "db", target_version: "v1").cli_args
    assert_equal [ "accessory", "reboot", "cache", "--version", "v1" ],
                 action("accessory_reboot", target: "cache", target_version: "v1").cli_args
  end

  test "accessory actions touch only that accessory's hosts" do
    assert_equal [ "10.0.0.3" ], action("accessory_restart", target: "db").affected_hosts
    assert_equal %w[10.0.0.1 10.0.0.2], action("accessory_reboot", target: "cache").affected_hosts
  end

  test "prune covers accessory hosts too, since Kamal runs it on every host" do
    assert_equal %w[10.0.0.1 10.0.0.2 10.0.0.3], action("prune").affected_hosts
  end

  test "restart can be limited to one of the app's hosts" do
    restart = action("restart", target_version: "abc1234", target: "10.0.0.2")

    assert_equal [ "app", "boot", "--version", "abc1234", "--hosts", "10.0.0.2" ], restart.cli_args
    assert_equal [ "10.0.0.2" ], restart.affected_hosts
  end

  test "an accessory the config doesn't declare is rejected" do
    assert_raises(Actions::Base::InvalidTarget) { action("accessory_restart", target: "mysql").validate_target! }
    assert_raises(Actions::Base::InvalidTarget) { action("accessory_reboot", target: "mysql").cli_args }
  end

  test "accessory actions need a target" do
    assert_raises(Actions::Base::InvalidTarget) { action("accessory_restart").validate_target! }
  end

  test "restart refuses a host outside the app's hosts, including accessory-only hosts" do
    assert_raises(Actions::Base::InvalidTarget) { action("restart", target: "10.0.0.9").validate_target! }
    assert_raises(Actions::Base::InvalidTarget) { action("restart", target: "10.0.0.3").validate_target! }
  end

  test "actions that take no target refuse one" do
    %w[maintenance live proxy_restart prune start stop].each do |name|
      assert_raises(Actions::Base::InvalidTarget, name) { action(name, target: "db").validate_target! }
    end
  end

  # The value lands in argv: no shell, but Thor would still read "--..." as an option.
  test "a target that looks like an option is rejected even before the config lookup" do
    assert_raises(Actions::Base::InvalidTarget) { action("accessory_restart", target: "--help").validate_target! }
  end

  test "lock and confirmation flags follow spec §5" do
    expectations = {
      "maintenance"       => { lock: true, confirm: true },
      "live"              => { lock: true, confirm: false },
      "accessory_restart" => { lock: true, confirm: false },
      "accessory_reboot"  => { lock: true, confirm: true },
      "proxy_restart"     => { lock: true, confirm: true },
      "prune"             => { lock: true, confirm: false }
    }

    expectations.each do |name, flags|
      klass = Actions::Base.find(name)
      assert klass.mutating?, "#{name} changes production state"
      assert_equal flags[:lock], klass.requires_lock?, "#{name} requires_lock?"
      assert_equal flags[:confirm], klass.confirm_by_name?, "#{name} confirm_by_name?"
    end
  end
end
