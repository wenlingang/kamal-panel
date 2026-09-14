# 围绕某个应用的权限。暴露的是【能力】而不是角色——调用方永远不该问
# 「这个人是不是 admin」，只问「这个人能不能做这件事」。角色与成员关系
# 怎么合成能力，只在这一个文件里回答。
#
# managed_app 允许为 nil：接入新应用时还没有应用可谈，而 create_app? 本来
# 也不看具体是哪个应用。
class ManagedAppPolicy
  def initialize(user, managed_app = nil)
    @user = user
    @managed_app = managed_app
  end

  # 可见性不按成员关系收窄（设计 11 第 3.1 节）：总览的价值在于一屏看全，
  # 版本漂移这类问题常常是跨应用比较才看得出来的。看得见与动得了是两件事。
  # 可见性从不因停用而收窄——看不见就没法把它启用回来。
  def show? = true

  # 停用的应用不接受任何动作。这道守卫放在这里而不是各个控制器里，是因为
  # 重启、回滚、强制解锁、看日志、重生成 token、编辑全都从 act? / view_logs?
  # / run? 走：挡在源头，就不存在"某一条路径忘了判断"。
  def act? = !deactivated? && (user.admin? || (user.developer? && member?))

  def view_logs? = !deactivated? && (act? || user.ops?)

  def regenerate_hook_token? = act?

  def create_app?     = user.admin?

  # 改绑凭据实质上是"把哪把私钥交给这个应用用"。凭据本身是 admin 独占管理的
  # （设计 12），所以决定哪个应用能用哪一条，同样只能是 admin——否则 developer
  # 可以给自己的应用换上池子里任何一把钥匙，绕过那条独占。
  def assign_credentials? = user.admin?

  # 停用会释放凭据绑定，而凭据是 admin 独占管理的（设计 12）。
  def deactivate? = user.admin?
  def manage_members? = user.admin?

  # 动作类只声明自己会不会改变线上状态，由这里解释谁能执行。角色字符串
  # 一旦写回动作类，授权规则就同时活在两个地方了。
  def run?(action_class) = action_class.mutating? ? act? : view_logs?

  private
    attr_reader :user, :managed_app

    def member? = managed_app.present? && managed_app.member_ids.include?(user.id)

    def deactivated? = managed_app.present? && managed_app.deactivated?
end
