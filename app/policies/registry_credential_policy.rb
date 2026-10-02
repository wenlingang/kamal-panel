# 有一个唯一的落点，而不是让 Current.user.admin? 散在控制器和视图里。
class RegistryCredentialPolicy
  def initialize(user, subject = nil)
    @user = user
    @subject = subject
  end

  def manage? = user.admin?

  private
    attr_reader :user, :subject
end
