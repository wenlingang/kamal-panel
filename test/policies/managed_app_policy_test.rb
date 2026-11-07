require "test_helper"

class ManagedAppPolicyTest < ActiveSupport::TestCase
  setup do
    @mine = ManagedApp.create!(name: "mine",
                               config_yaml: file_fixture("simple_deploy.yml").read,
                               destination: "production")
    @theirs = ManagedApp.create!(name: "theirs",
                                 config_yaml: file_fixture("simple_deploy.yml").read,
                                 destination: "production")

    @admin     = users(:two)
    @developer = users(:three)
    @ops       = users(:one)

    AppMembership.create!(user: @developer, managed_app: @mine)
  end

  def policy(user, app) = ManagedAppPolicy.new(user, app)

  test "act: developer can only act on owned apps" do
    assert_predicate policy(@developer, @mine), :act?
    refute_predicate policy(@developer, @theirs), :act?
  end

  test "act: ops cannot act on any app, even if wrongly added as a member" do
    AppMembership.create!(user: @ops, managed_app: @mine)

    refute_predicate policy(@ops, @mine), :act?,
      "ops permissions come from the site-wide role; a membership row must not grant extra action permission"
  end

  # Two of the plainest stand-ins: run? only cares how the action class answers mutating?,
  # not anything else about it. We don't change Actions::Base's defaults -- that would turn
  # a test of an authorization rule into a change to the action registry.
  class ReadOnlyAction
    def self.mutating? = false
  end

  class MutatingAction
    def self.mutating? = true
  end

  test "run?: actions that change production state are narrowed by action permission" do
    refute policy(@ops, @mine).run?(MutatingAction),
      "ops must never run actions that change production state"
    refute policy(@developer, @theirs).run?(MutatingAction),
      "developer must not be able to act on apps outside their own"
    assert policy(@developer, @mine).run?(MutatingAction)
    assert policy(@admin, @theirs).run?(MutatingAction)
  end

  # A deactivated app accepts no actions. The guard sits at the top of the policy, so one
  # change blocks restart, rollback, force unlock, view logs, regenerate token and edit
  # at once -- they all go through these methods.
  test "deactivated app: nobody can act on it" do
    @mine.deactivate!

    refute_predicate policy(@admin, @mine), :act?
    refute_predicate policy(@developer, @mine), :act?
    refute_predicate policy(@admin, @mine), :regenerate_hook_token?
  end
end
