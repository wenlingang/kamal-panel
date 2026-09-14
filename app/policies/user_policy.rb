# 人员管理。逻辑简单到只有一行，但它存在的意义不是逻辑复杂，而是让
# 「谁能管人」这句话有一个唯一的落点——否则它会以 Current.user.admin?
# 的形式散落在控制器、视图和测试里。
class UserPolicy
  def initialize(user, subject = nil)
    @user = user
    @subject = subject
  end

  def manage? = user.admin?

  private
    attr_reader :user, :subject
end
