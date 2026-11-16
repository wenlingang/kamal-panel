# Every few minutes: start the backups that are due. Each plan is claimed (BackupPlan#claim_due!)
# before its job is enqueued, so overlapping ticks start one backup per plan, not two.
class ScheduleBackupsJob < ApplicationJob
  queue_as :default

  def perform(now: Time.current)
    BackupPlan.due(now).includes(:managed_app).find_each do |plan|
      next if plan.managed_app.deactivated?

      RunBackupJob.perform_later(plan) if plan.claim_due!(now)
    end

    fail_stale_runs(now)
  end

  private
    # A run the panel lost track of (it restarted mid-dump) would otherwise say "running" forever.
    def fail_stale_runs(now)
      BackupRun.where(state: "running").where(started_at: ...(now - BackupRun::STALE_AFTER)).find_each do |run|
        run.update!(state: "failed", error: I18n.t("backups.runner.interrupted"), finished_at: now)
      end
    end
end
