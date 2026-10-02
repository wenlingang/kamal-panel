require "test_helper"

class Actions::BaseTest < ActiveSupport::TestCase
  test "only accepts registered action names" do
    assert_equal Actions::Restart, Actions::Base.find("restart")
    assert_equal Actions::Stop,    Actions::Base.find("stop")
    assert_equal Actions::Start,   Actions::Base.find("start")
  end

  test "rejects unknown action names because the panel never runs arbitrary commands" do
    assert_raises(Actions::Base::UnknownAction) { Actions::Base.find("exec") }
    assert_raises(Actions::Base::UnknownAction) { Actions::Base.find("rm -rf /") }
  end

  test "rejects an action name even when it spells a real Ruby constant, so safety does not rely on strings failing to match" do
    # "exec" and "rm -rf /" happen not to spell any real constant, so these two examples alone can't
    # tell whether find goes through an explicit table (actually safe) or looks classes up
    # dynamically by name (unsafe, equivalent to executing the action name as code) -- both
    # implementations behave the same on these two inputs. "base" gets camelized to "Base", and
    # Actions::Base is a real constant: if find used dynamic lookup like
    # `"Actions::#{name.camelize}".constantize`, it would wrongly return this as a valid action here
    # instead of raising UnknownAction.
    assert_raises(Actions::Base::UnknownAction) { Actions::Base.find("base") }
  end

  test "every action declares whether it mutates production state and whether it needs a lock" do
    Actions::Base.all.each do |klass|
      assert_includes [ true, false ], klass.mutating?, "#{klass} does not declare whether it changes production state"
      assert_includes [ true, false ], klass.requires_lock?, "#{klass} does not declare whether it needs a lock"
    end
  end
end
