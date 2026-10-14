class AuditLogsController < ApplicationController
  def index
    @filter = AuditLogFilter.new(**params.permit(:app_id, :user_id, :result, :before).to_h.symbolize_keys)
    @page = @filter.page

    # Everyone signed in reads this page, but only admins see the people list. So the dropdowns
    # offer only actors and apps that already appear in the log, never the full rosters.
    @apps = ManagedApp.where(id: AuditLog.select(:managed_app_id)).order(:name)
    @users = User.where(id: AuditLog.select(:user_id)).order(:email_address)
  end
end
