require "test_helper"

class CredentialPolicyTest < ActiveSupport::TestCase
  test "only admin can manage credentials" do
    assert_predicate CredentialPolicy.new(users(:two), nil), :manage?
    refute_predicate CredentialPolicy.new(users(:three), nil), :manage?
    refute_predicate CredentialPolicy.new(users(:one), nil), :manage?

    assert_predicate RegistryCredentialPolicy.new(users(:two), nil), :manage?
    refute_predicate RegistryCredentialPolicy.new(users(:three), nil), :manage?
  end
end
