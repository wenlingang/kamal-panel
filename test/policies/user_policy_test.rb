require "test_helper"

class UserPolicyTest < ActiveSupport::TestCase
  test "只有 admin 能管人" do
    assert_predicate UserPolicy.new(users(:two), nil), :manage?
    refute_predicate UserPolicy.new(users(:three), nil), :manage?
    refute_predicate UserPolicy.new(users(:one), nil), :manage?
  end
end
