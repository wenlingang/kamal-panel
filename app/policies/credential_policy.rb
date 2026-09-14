# 凭据只有 admin 能管。逻辑简单不是问题——它存在的意义是让"谁能管凭据"
# 有一个唯一的落点，而不是让 Current.user.admin? 散在控制器和视图里。
class CredentialPolicy
  def initialize(user, subject = nil)
    @user = user
    @subject = subject
  end

  def manage? = user.admin?

  private
    attr_reader :user, :subject
end
