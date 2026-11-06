# Alert rules: everyone signed in sees them (knowing what is watched is part of reading an alert);
# only admin changes them (spec 9).
class AlertRulePolicy
  def initialize(user, subject = nil)
    @user = user
    @subject = subject
  end

  def manage? = user.admin?

  private
    attr_reader :user, :subject
end
