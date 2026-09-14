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
    # 「exec」「rm -rf /」不巧都拼不出真实常量，光靠这两个例子测不出
    # find 到底是走显式表（真正安全）还是按名字动态查找类（不安全，
    # 等价于把动作名当代码执行）——两种实现在这两个输入上表现一样。
    # "base" 会被 camelize 成 "Base"，而 Actions::Base 是一个真实存在
    # 的常量：若 find 走的是 `"Actions::#{name.camelize}".constantize`
    # 这类动态查找，这里就会错误地把它当成一个合法动作返回，而不是
    # 抛 UnknownAction。
    assert_raises(Actions::Base::UnknownAction) { Actions::Base.find("base") }
  end

  test "每个动作都声明是否会改变线上状态与是否要锁" do
    Actions::Base.all.each do |klass|
      assert_includes [ true, false ], klass.mutating?, "#{klass} 未声明是否会改变线上状态"
      assert_includes [ true, false ], klass.requires_lock?, "#{klass} 未声明是否要锁"
    end
  end
end
