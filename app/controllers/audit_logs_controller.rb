class AuditLogsController < ApplicationController
  def index
    @audit_logs = AuditLog.includes(:user, :managed_app, :target_user)
                          .order(created_at: :desc).limit(200)
  end
end
