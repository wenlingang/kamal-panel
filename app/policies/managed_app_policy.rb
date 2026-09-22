class ManagedAppPolicy
  def initialize(user, managed_app = nil)
    @user = user
    @managed_app = managed_app
  end

  def show? = true

  def act? = !deactivated? && (user.admin? || (user.developer? && member?))

  def view_logs? = !deactivated? && (act? || user.ops?)

  def regenerate_hook_token? = act?

  def create_app?     = user.admin?

  def assign_credentials? = user.admin?

  # 停用会释放凭据绑定，而凭据是 admin 独占管理的（设计 12）。
  def deactivate? = user.admin?
  def manage_members? = user.admin?

  # 一旦写回动作类，授权规则就同时活在两个地方了。
  def run?(action_class) = action_class.mutating? ? act? : view_logs?

  private
    attr_reader :user, :managed_app

    def member? = managed_app.present? && managed_app.member_ids.include?(user.id)

    def deactivated? = managed_app.present? && managed_app.deactivated?
end
