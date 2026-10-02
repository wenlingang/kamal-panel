require "test_helper"

class Actions::LogsTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog",
                              config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  test "is in the closed action set" do
    assert_equal Actions::Logs, Actions::Base.find("logs")
  end

  test "does not take the deploy lock, since viewing logs does not mutate production" do
    refute_predicate Actions::Logs, :requires_lock?
  end

  test "is not an action that mutates production state" do
    refute_predicate Actions::Logs, :mutating?
  end

  test "all other actions are mutating by default" do
    (Actions::Base.all - [ Actions::Logs ]).each do |klass|
      assert_predicate klass, :mutating?, "#{klass} must explicitly declare whether it mutates production state"
    end
  end

  test "command is kamal app logs with a line limit" do
    assert_equal [ "app", "logs", "--lines", "200" ], Actions::Logs.new(@app).cli_args
  end
end
