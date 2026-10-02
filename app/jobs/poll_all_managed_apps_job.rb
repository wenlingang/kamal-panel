# Triggered on a schedule by Solid Queue's recurring.
# Each app decides on its own cadence whether this round should run (spec 6.3).
class PollAllManagedAppsJob < ApplicationJob
  queue_as :default

  def perform
    # accumulate one failure observation.
    ManagedApp.active.find_each do |managed_app|
      PollManagedAppJob.perform_later(managed_app) if claim_slot!(managed_app)
    end
  end

  private
    # Use the atomic write of unless_exist to "claim" this round — rather than reading last_run
    # first and then writing.
    def claim_slot!(managed_app)
      Rails.cache.write(
        PollCadence.last_run_key(managed_app),
        Time.current,
        expires_in: PollCadence.interval_for(managed_app),
        unless_exist: true
      )
    end
end
