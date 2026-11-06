# Git connections hold API tokens, managed exclusively by admin like credentials (spec 9).
class GitConnectionPolicy
  def initialize(user, subject = nil)
    @user = user
    @subject = subject
  end

  def manage? = user.admin?

  private
    attr_reader :user, :subject
end
