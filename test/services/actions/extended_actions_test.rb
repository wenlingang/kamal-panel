require "test_helper"

# The actions added for "operations up front" (spec §5): exact argv, lock/confirm flags, and the
# target check against the app's own parsed config.
class Actions::ExtendedActionsTest < ActiveSupport::TestCase
  def build_app(fixture = "accessory_deploy.yml")
    ManagedApp.new(name: "blog", config_yaml: file_fixture(fixture).read, destination: "production")
  end

  def action(name, **options) = Actions::Base.find(name).new(build_app, **options)

  test "restart refuses a host outside the app's hosts, including accessory-only hosts" do
    assert_raises(Actions::Base::InvalidTarget) { action("restart", target: "10.0.0.9").validate_target! }
    assert_raises(Actions::Base::InvalidTarget) { action("restart", target: "10.0.0.3").validate_target! }
  end

  # The value lands in argv: no shell, but Thor would still read "--..." as an option.
  test "a target that looks like an option is rejected even before the config lookup" do
    assert_raises(Actions::Base::InvalidTarget) { action("accessory_restart", target: "--help").validate_target! }
  end
end
