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

  # 两个最朴素的替身：run? 只关心动作类怎么回答 mutating?，不关心它别的任何事。
  # 不去改 Actions::Base 的默认值——那会把一条授权规则的测试变成对动作注册表的改动。
  class ReadOnlyAction
    def self.mutating? = false
  end

  class MutatingAction
    def self.mutating? = true
  end

  # run? 是每个会改变线上状态的请求都要过的那个方法，两条分支都得钉住。
  # 只读分支眼下还没有真实动作类走到（已注册的五个动作 mutating? 全是 true），
  # Task 6 的 Actions::Logs 才会用上它——正因为如此，它现在更需要一条测试，
  # 否则它就是一段没人验证过的死代码，等到有人依赖它时才发现写错了。
  test "run?：只读动作跟着 view_logs? 走，而不是跟着可见性走" do
    assert policy(@ops, @theirs).run?(ReadOnlyAction),
      "ops 的价值就是查问题，只读动作必须对它全站开放"
    assert policy(@admin, @theirs).run?(ReadOnlyAction)
    assert policy(@developer, @mine).run?(ReadOnlyAction)

    # 注意这里是 refute。看得见 ≠ 读得到日志：show? 对所有人为真（总览要一屏看全），
    # 但日志里有应用自己打出来的东西，它按名下收窄——见上面的 view_logs? 用例。
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

  # 停用的应用不接受任何动作。守卫放在 policy 顶部，一处改动同时挡住重启、
  # 回滚、强制解锁、看日志、重生成 token 和编辑——它们都从这几个方法走。
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

  # 看不见就没法启用它。
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
