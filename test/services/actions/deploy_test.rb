require "test_helper"

class Actions::DeployTest < ActiveSupport::TestCase
  def build_app
    ManagedApp.new(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production")
  end

  test "deploys an already-pushed image: --skip-push with the version explicit" do
    action = Actions::Deploy.new(build_app, target_version: "abc1234")

    assert_equal [ "deploy", "--skip-push", "--version", "abc1234" ], action.cli_args
    assert_predicate Actions::Deploy, :mutating?
    assert_predicate Actions::Deploy, :requires_lock?
    assert_predicate Actions::Deploy, :records_deploy_event?
    assert_not Actions::Deploy.confirm_by_name?
    assert_equal "deploy", Actions::Deploy.action_name
  end

  test "is part of the closed action set" do
    assert_equal Actions::Deploy, Actions::Base.find("deploy")
  end

  test "requires a version" do
    assert_raises(Actions::Base::InvalidVersion) { Actions::Deploy.new(build_app, target_version: nil).validate! }
    assert_raises(Actions::Base::InvalidVersion) { Actions::Deploy.new(build_app, target_version: "").validate! }
  end

  test "accepts image-tag shaped versions" do
    [ "a" * 40, "abc1234", "v1.4.2", "release_2026-11-05", "1.0" ].each do |version|
      assert_nil Actions::Deploy.new(build_app, target_version: version).validate!, version
    end
  end

  # The version lands in argv. Anything starting with "-" would be parsed by Thor as an option.
  test "rejects anything that could be read as an option or isn't a tag" do
    [ "-x", "--skip-push", "--version=evil", ".hidden", "a b", "v1;rm -rf /", "a" * 129, "版本", "v1\n" ].each do |version|
      assert_raises(Actions::Base::InvalidVersion, version.inspect) do
        assert_nil Actions::Deploy.new(build_app, target_version: version).validate!, version
      end
    end
  end

  test "the same version check applies to other actions that take one" do
    assert_raises(Actions::Base::InvalidVersion) { Actions::Restart.new(build_app, target_version: "--hosts").validate! }
    assert_raises(Actions::Base::InvalidVersion) { Actions::Rollback.new(build_app, target_version: nil).validate! }
    assert_nothing_raised { Actions::Stop.new(build_app).validate! }
  end
end
