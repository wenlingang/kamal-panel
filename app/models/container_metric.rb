# One container's resource usage in one collection minute (Collectors::MetricsCollector).
# Append-only like Observation; pruned after PruneObservationsJob::METRICS_RETENTION.
class ContainerMetric < ApplicationRecord
  KINDS = %w[app accessory proxy].freeze

  belongs_to :managed_app

  validates :host, :container_name, :source, :sampled_at, presence: true
  validates :kind, inclusion: { in: KINDS }

  # kamal-proxy is shared by every app on its host: it is shown, but left out of the app's own
  # totals (overview card, cpu / memory alerts) so one busy proxy doesn't page every app.
  scope :own, -> { where.not(kind: "proxy") }

  def readonly?
    persisted?
  end

  # "web @ 10.1.0.11": a series survives deploys (the container name changes with the version).
  def series_key = "#{source}@#{host}"
end
