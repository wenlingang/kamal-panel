# Notification channels hold webhook URLs and signing secrets, managed exclusively by admin like
# Git connections (spec 9). The read-only list on the alerts page shows only masked targets.
class NotificationChannelPolicy
  def initialize(user, subject = nil)
    @user = user
    @subject = subject
  end

  def manage? = user.admin?

  private
    attr_reader :user, :subject
end
