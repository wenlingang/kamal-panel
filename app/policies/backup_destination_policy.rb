# Backup destinations hold object-storage keys that can read every dump: admin only, like
# notification channels and Git connections.
class BackupDestinationPolicy
  def initialize(user, subject = nil)
    @user = user
    @subject = subject
  end

  def manage? = user.admin?

  private
    attr_reader :user, :subject
end
