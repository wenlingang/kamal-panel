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

  test "view: all three roles can view any app" do
    [ @admin, @developer, @ops ].each do |user|
      assert_predicate policy(user, @theirs), :show?
    end
  end

  test "act: admin can act on any app" do
    assert_predicate policy(@admin, @mine), :act?
    assert_predicate policy(@admin, @theirs), :act?
  end

  test "act: developer can only act on owned apps" do
    assert_predicate policy(@developer, @mine), :act?
    refute_predicate policy(@developer, @theirs), :act?
  end

  test "act: ops cannot act on any app, even if wrongly added as a member" do
    AppMembership.create!(user: @ops, managed_app: @mine)

    refute_predicate policy(@ops, @mine), :act?,
      "ops permissions come from the site-wide role; a membership row must not grant extra action permission"
  end

  test "logs: ops can view all, developer only owned apps, admin all" do
    assert_predicate policy(@ops, @theirs), :view_logs?
    assert_predicate policy(@admin, @theirs), :view_logs?
    assert_predicate policy(@developer, @mine), :view_logs?
    refute_predicate policy(@developer, @theirs), :view_logs?
  end

  test "regenerating the hook token requires the same permission as acting" do
    assert_predicate policy(@developer, @mine), :regenerate_hook_token?
    refute_predicate policy(@developer, @theirs), :regenerate_hook_token?
    refute_predicate policy(@ops, @mine), :regenerate_hook_token?
  end

  test "onboarding apps and managing members are admin-only" do
    assert_predicate policy(@admin, nil), :create_app?
    refute_predicate policy(@developer, nil), :create_app?
    refute_predicate policy(@ops, nil), :create_app?

    assert_predicate policy(@admin, @mine), :manage_members?
    refute_predicate policy(@developer, @mine), :manage_members?
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

  # run? is the method every request that changes live state goes through, so both branches must be
  # pinned. The read-only branch has no real action class reaching it yet (all five registered
  # actions have mutating? true); Task 6's Actions::Logs will be the first to use it -- which is
  # exactly why it needs a test now, otherwise it is dead code nobody has verified, and a bug would
  # only surface once someone depends on it.
  test "run?: read-only actions follow view_logs?, not visibility" do
    assert policy(@ops, @theirs).run?(ReadOnlyAction),
      "the point of ops is investigating problems, so read-only actions must be open to it site-wide"
    assert policy(@admin, @theirs).run?(ReadOnlyAction)
    assert policy(@developer, @mine).run?(ReadOnlyAction)

    # Note this is refute. Visible != can read logs: show? is true for everyone (the
    # overview must be viewable at a glance), but logs contain things the app itself printed,
    # so access is narrowed by ownership -- see the view_logs? case above.
    refute policy(@developer, @theirs).run?(ReadOnlyAction),
      "developer can see the status of apps outside their own but cannot read their logs"
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

  test "deactivated app: logs cannot be viewed either, not even by ops" do
    @mine.deactivate!

    refute_predicate policy(@ops, @mine), :view_logs?
    refute_predicate policy(@admin, @mine), :view_logs?
  end

  # Can't enable it if you can't see it.
  test "deactivated app is still visible" do
    @mine.deactivate!

    assert_predicate policy(@ops, @mine), :show?
  end

  test "only admin can deactivate or activate" do
    assert_predicate policy(@admin, @mine), :deactivate?
    refute_predicate policy(@developer, @mine), :deactivate?
    refute_predicate policy(@ops, @mine), :deactivate?
  end
end
