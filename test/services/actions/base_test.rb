require "test_helper"

class Actions::BaseTest < ActiveSupport::TestCase
  test "只认已注册的动作名" do
    assert_equal Actions::Restart, Actions::Base.find("restart")
    assert_equal Actions::Stop,    Actions::Base.find("stop")
    assert_equal Actions::Start,   Actions::Base.find("start")
  end

  test "未知动作名被拒绝——面板永远不执行任意命令" do
    assert_raises(Actions::Base::UnknownAction) { Actions::Base.find("exec") }
    assert_raises(Actions::Base::UnknownAction) { Actions::Base.find("rm -rf /") }
  end

  test "动作名恰好能拼出一个真实存在的 Ruby 常量时也必须被拒绝——不是靠字符串猜不中才安全" do
    # "exec" and "rm -rf /" happen not to spell any real constant, so these two examples alone can't
    # tell whether find goes through an explicit table (actually safe) or looks classes up
    # dynamically by name (unsafe, equivalent to executing the action name as code) -- both
    # implementations behave the same on these two inputs. "base" gets camelized to "Base", and
    # Actions::Base is a real constant: if find used dynamic lookup like
    # `"Actions::#{name.camelize}".constantize`, it would wrongly return this as a valid action here
    # instead of raising UnknownAction.
    assert_raises(Actions::Base::UnknownAction) { Actions::Base.find("base") }
  end

  test "每个动作都声明是否会改变线上状态与是否要锁" do
    Actions::Base.all.each do |klass|
      assert_includes [ true, false ], klass.mutating?, "#{klass} 未声明是否会改变线上状态"
      assert_includes [ true, false ], klass.requires_lock?, "#{klass} 未声明是否要锁"
    end
  end
end
