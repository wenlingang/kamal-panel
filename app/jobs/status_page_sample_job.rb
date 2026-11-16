# Every 10 minutes: one sample per app listed on the public status page (StatusSample), from the
# state the panel already collected. Up and healthy counts as ok; up but with unhealthy containers
# or disagreeing versions as degraded; unreachable, stale or broken config as down. An app never
# collected yet isn't sampled.
class StatusPageSampleJob < ApplicationJob
  queue_as :default

  def perform(now: Time.current)
    ManagedApp.active.where(public_status: true).find_each do |app|
      level = app.last_poll_error.present? ? :down : StatusPage.level_of(ManagedAppStatus.new(app))
      next if level == :unknown

      sample = StatusSample.find_or_create_by!(managed_app: app, day: now.to_date)
      StatusSample.where(id: sample.id).update_all(
        [ "total = total + 1, ok = ok + ?, degraded = degraded + ?, updated_at = ?",
          level == :ok ? 1 : 0, level == :degraded ? 1 : 0, now ]
      )
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    StatusSample.where(day: ...(now.to_date - StatusPage::DAYS)).delete_all
  end
end
