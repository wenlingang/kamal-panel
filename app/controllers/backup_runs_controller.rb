# Downloading one dump: a link to the object signed for a few minutes, so the file goes straight
# from the bucket to the browser and the panel never streams it. A dump is the whole database, so
# only people who may act on the app get one, and each download is audited.
class BackupRunsController < ApplicationController
  DOWNLOAD_LINK_TTL = 5.minutes

  def download
    managed_app = ManagedApp.find(params[:managed_app_id])
    return unless require_act!(managed_app)

    run = managed_app.backup_runs.find(params[:id])
    return redirect_to(managed_app_path(managed_app, tab: "backups"), alert: t("flash.backup_run.gone")) unless run.downloadable?

    AuditLog.record_access!(user: Current.user, action_name: "backup.download", managed_app:, detail: run.object_key)
    url = run.backup_plan.backup_destination.storage.presigned_url(run.object_key, expires_in: DOWNLOAD_LINK_TTL.to_i)
    redirect_to url, allow_other_host: true
  end

  private
    def require_act!(managed_app)
      return true if policy_for(managed_app).act?

      redirect_to root_path, alert: t("flash.no_permission")
      false
    end
end
