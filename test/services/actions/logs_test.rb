require "test_helper"

class Actions::LogsTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog",
                              config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  test "在封闭动作集里" do
    assert_equal Actions::Logs, Actions::Base.find("logs")
  end

  test "不取部署锁——看日志不改变线上状态，不该跟一次正在进行的部署抢锁" do
    refute_predicate Actions::Logs, :requires_lock?
  end

  test "不是改变线上状态的动作" do
    refute_predicate Actions::Logs, :mutating?
  end

  test "其余动作默认都是改变线上状态的" do
    (Actions::Base.all - [ Actions::Logs ]).each do |klass|
      assert_predicate klass, :mutating?, "#{klass} 必须显式表态自己会不会改线上状态"
    end
  end

  test "命令是 kamal app logs，带行数上限" do
    assert_equal [ "app", "logs", "--lines", "200" ], Actions::Logs.new(@app).cli_args
  end
end
