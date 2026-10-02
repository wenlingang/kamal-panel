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

  test "看：三档角色都能看任何应用" do
    [ @admin, @developer, @ops ].each do |user|
      assert_predicate policy(user, @theirs), :show?
    end
  end

  test "动：admin 对任何应用都能动" do
    assert_predicate policy(@admin, @mine), :act?
    assert_predicate policy(@admin, @theirs), :act?
  end

  test "动：developer 只能动名下的应用" do
    assert_predicate policy(@developer, @mine), :act?
    refute_predicate policy(@developer, @theirs), :act?
  end

  test "动：ops 一个都不能动，哪怕被错误地加成了成员" do
    AppMembership.create!(user: @ops, managed_app: @mine)

    refute_predicate policy(@ops, @mine), :act?,
      "ops 的权限来自全站角色，成员行不该给它额外的动作权限"
  end

  test "日志：ops 全站可看，developer 只看名下，admin 全站" do
    assert_predicate policy(@ops, @theirs), :view_logs?
    assert_predicate policy(@admin, @theirs), :view_logs?
    assert_predicate policy(@developer, @mine), :view_logs?
    refute_predicate policy(@developer, @theirs), :view_logs?
  end

  test "重生成上报 token 与动作同权" do
    assert_predicate policy(@developer, @mine), :regenerate_hook_token?
    refute_predicate policy(@developer, @theirs), :regenerate_hook_token?
    refute_predicate policy(@ops, @mine), :regenerate_hook_token?
  end

  test "接入应用与管理成员是 admin 独占" do
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
  test "run?：只读动作跟着 view_logs? 走，而不是跟着可见性走" do
    assert policy(@ops, @theirs).run?(ReadOnlyAction),
      "ops 的价值就是查问题，只读动作必须对它全站开放"
    assert policy(@admin, @theirs).run?(ReadOnlyAction)
    assert policy(@developer, @mine).run?(ReadOnlyAction)

    # Note this is refute. Visible != can read logs: show? is true for everyone (the
    # overview must be viewable at a glance), but logs contain things the app itself printed,
    # so access is narrowed by ownership -- see the view_logs? case above.
    refute policy(@developer, @theirs).run?(ReadOnlyAction),
      "developer 对名下之外的应用能看见状态，但不能读它的日志"
  end

  test "run?：会改变线上状态的动作按动作权限收窄" do
    refute policy(@ops, @mine).run?(MutatingAction),
      "ops 无论如何都不该执行会改变线上状态的动作"
    refute policy(@developer, @theirs).run?(MutatingAction),
      "developer 对名下之外的应用不该能动"
    assert policy(@developer, @mine).run?(MutatingAction)
    assert policy(@admin, @theirs).run?(MutatingAction)
  end

  # A deactivated app accepts no actions. The guard sits at the top of the policy, so one
  # change blocks restart, rollback, force unlock, view logs, regenerate token and edit
  # at once -- they all go through these methods.
  test "停用的应用：谁都动不了它" do
    @mine.deactivate!

    refute_predicate policy(@admin, @mine), :act?
    refute_predicate policy(@developer, @mine), :act?
    refute_predicate policy(@admin, @mine), :regenerate_hook_token?
  end

  test "停用的应用：日志也看不了，ops 也不行" do
    @mine.deactivate!

    refute_predicate policy(@ops, @mine), :view_logs?
    refute_predicate policy(@admin, @mine), :view_logs?
  end

  # Can't enable it if you can't see it.
  test "停用的应用仍然看得见" do
    @mine.deactivate!

    assert_predicate policy(@ops, @mine), :show?
  end

  test "只有 admin 能停用或启用" do
    assert_predicate policy(@admin, @mine), :deactivate?
    refute_predicate policy(@developer, @mine), :deactivate?
    refute_predicate policy(@ops, @mine), :deactivate?
  end
end
