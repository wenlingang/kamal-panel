# Recurring (config/recurring.yml, every minute): one CollectMetricsJob per app that can be
# collected. Unlike the status poll there is no per-app cadence: a chart wants evenly spaced
# samples whether or not anyone is looking.
class CollectAllMetricsJob < ApplicationJob
  queue_as :default

  # The round is spread over this window instead of enqueued all at once: every job opens SSH
  # sessions and may parse a deploy.yml, and a dozen of them landing in the same second pins the
  # panel's CPU, on a host that usually runs production apps too. The window stays well under the
  # one-minute schedule so a round finishes before the next begins (metrics.spread in
  # config/collection.yml, at most 55 seconds).
  def perform
    apps = ManagedApp.active.where.not(ssh_credential_id: nil).where(last_poll_error: nil).order(:id).to_a

    apps.each_with_index do |managed_app, index|
      CollectMetricsJob.set(wait: spread * index / apps.size).perform_later(managed_app)
    end
  end

  private
    def spread = CollectionSettings.current.metrics_spread
end
