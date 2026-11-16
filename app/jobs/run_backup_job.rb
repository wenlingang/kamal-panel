# One backup of one plan (BackupRunner), started by the schedule or by someone pressing "Back up
# now". On its own queue: a dump can take minutes and must hold up neither deploys nor collection.
class RunBackupJob < ApplicationJob
  queue_as :backups

  # Two dumps of the same database at once help nobody; the second one is dropped.
  limits_concurrency to: 1, key: ->(plan, *) { "backup_plan_#{plan.id}" }, duration: 2.hours, on_conflict: :discard

  discard_on ActiveJob::DeserializationError

  def perform(plan, user = nil)
    return if plan.managed_app.deactivated?

    BackupRunner.call(plan, user:)
  end
end
