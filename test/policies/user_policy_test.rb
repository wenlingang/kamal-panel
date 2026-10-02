require "test_helper"

class UserPolicyTest < ActiveSupport::TestCase
  test "only admin can manage users" do
    assert_predicate UserPolicy.new(users(:two), nil), :manage?
    refute_predicate UserPolicy.new(users(:three), nil), :manage?
    refute_predicate UserPolicy.new(users(:one), nil), :manage?
  end
end
