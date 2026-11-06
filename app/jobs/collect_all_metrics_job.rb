# Recurring (config/recurring.yml, every minute): one CollectMetricsJob per app that can be
# collected. Unlike the status poll there is no per-app cadence: a chart wants evenly spaced
# samples whether or not anyone is looking.
class CollectAllMetricsJob < ApplicationJob
  queue_as :default

  def perform
    ManagedApp.active.where.not(ssh_credential_id: nil).where(last_poll_error: nil).find_each do |managed_app|
      CollectMetricsJob.perform_later(managed_app)
    end
  end
end
