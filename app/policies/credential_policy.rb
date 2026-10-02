# has a single landing point, rather than scattering Current.user.admin? across controllers and
# views.
class CredentialPolicy
  def initialize(user, subject = nil)
    @user = user
    @subject = subject
  end

  def manage? = user.admin?

  private
    attr_reader :user, :subject
end
