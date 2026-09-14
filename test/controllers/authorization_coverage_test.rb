require "test_helper"

# 漏挂一个授权过滤器是这类重构最典型的事故，而它【不会让任何别的测试变红】
# ——那个动作照常工作，只是对谁都工作。这条测试是唯一能在 CI 里抓住它的东西。
#
# 这里的清单是人写的、故意写死的：它表达的是「这些动作必须被授权」这个意图，
# 而不是从代码里反推出来的事实。从代码反推的测试只会永远为真。
class AuthorizationCoverageTest < ActiveSupport::TestCase
  DECLARATIVE = {
    "ManagedAppsController" => %w[new create],
    "UsersController" => %w[index new create edit update deactivate reactivate],
    "CredentialsController" => %w[index new create edit update destroy],
    "RegistryCredentialsController" => %w[new create edit update destroy]
  }.freeze

  # 权限取决于 URL 里那个应用的动作没法用类宏声明（before_action 拿不到
  # params 指向的记录），它们在方法体里判断。这里列出它们，并在下面用一条
  # 源码断言确认那句判断还在——比"什么都不检查"强，比假装它们也是声明式的诚实。
  # RefreshesController#create 不在以上任何一张表里，这是刻意的：手动刷新是读动作
  # ——不取部署锁、不写审计、不改变线上任何状态，只是让一次本来就会自动发生的采集
  # 提前（设计 11 第 3.2 节，对三档角色一律开放）。别顺手把它"补"进来。
  INLINE = {
    "app/controllers/actions_controller.rb"     => [
      "ManagedAppPolicy.new(Current.user, app).run?",
      # show 会把动作的完整输出渲染出来，必须和发起动作走同一个判断。
      "ManagedAppPolicy.new(Current.user, @managed_app).run?(action_class)"
    ],
    "app/controllers/managed_apps_controller.rb" => [
      "require_permission!(:act, @managed_app)",
      "require_permission!(:deactivate, @managed_app)"
    ],
    "app/controllers/hook_tokens_controller.rb" => [
      "require_permission!(:regenerate_hook_token, app)"
    ]
  }.freeze

  test "声明式授权的控制器动作一个都不能漏" do
    DECLARATIVE.each do |controller_name, actions|
      controller = controller_name.constantize
      covered = controller.authorization_rules.flat_map { |rule| rule[:only] }.map(&:to_s)

      actions.each do |action|
        assert_includes covered, action,
          "#{controller_name}##{action} 没有声明授权规则——它现在对任何登录用户都开放"
      end
    end
  end

  test "行内授权的控制器里那句判断还在" do
    INLINE.each do |path, needles|
      source = Rails.root.join(path).read

      needles.each do |needle|
        assert_includes source, needle,
          "#{path} 里的授权判断不见了——这个动作现在对任何登录用户都开放"
      end
    end
  end
end
