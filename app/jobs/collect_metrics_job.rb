# One metrics round for one app (Collectors::MetricsCollector), fanned out by CollectAllMetricsJob.
#
# A round can take as long as the slowest host's `docker stats`, so a slow host could make rounds
# overlap; limits_concurrency drops the newer one (the next minute's round will come), and the
# unique indexes make a sample that slips through anyway a no-op.
class CollectMetricsJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: ->(managed_app) { "collect_metrics/#{managed_app.id}" },
                     duration: 5.minutes, on_conflict: :discard

  def perform(managed_app)
    return unless self.class.collectable?(managed_app)

    Collectors::MetricsCollector.call(managed_app)
  rescue Kamal::ConfigParser::ParseError
    # The status poll records and shows parse errors; metrics just wait for a config that parses.
    nil
  end

  # Metrics need SSH: no key, nothing to log in with. A config that didn't parse last time must not
  # be parsed here (PollManagedAppJob owns that error and clears it).
  def self.collectable?(managed_app)
    !managed_app.deactivated? && managed_app.ssh_credential_id.present? && managed_app.last_poll_error.blank?
  end
end
