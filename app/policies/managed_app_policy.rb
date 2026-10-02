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

  # Deactivating releases the credential binding, and credentials are managed exclusively by admin
  # (design 12).
  def deactivate? = user.admin?
  def manage_members? = user.admin?

  # once it is written back into the action class, the authorization rule lives in two places at
  # once.
  def run?(action_class) = action_class.mutating? ? act? : view_logs?

  private
    attr_reader :user, :managed_app

    def member? = managed_app.present? && managed_app.member_ids.include?(user.id)

    def deactivated? = managed_app.present? && managed_app.deactivated?
end
