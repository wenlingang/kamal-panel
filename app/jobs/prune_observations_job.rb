# Clean up the panel's accumulating operational data: everything collected keeps 7 days (the owner's
# call), which is also as far back as any chart or history view looks.
#
# Observation / ProxyTarget are append-only snapshots. Keep [two] anchors per host past the cutoff:
# the latest overall, and the latest reachable — keeping only the former means the longer a host is
# unreachable, the sooner it loses its history.
#
# Not pruned here, on purpose: audit logs (undeletable by design) and deploy events (a small,
# permanent record of what was released when, which rollbacks and post-mortems rely on).
class PruneObservationsJob < ApplicationJob
  queue_as :default

  RETENTION = 7.days
  GROUP_BY = [ :managed_app_id, :host ].freeze
  # Metrics are a time series, not state: no anchors to keep.
  METRICS_RETENTION = RETENTION

  def perform
    prune(Observation) + prune(ProxyTarget) + prune_metrics + prune_alert_events
  end

  private
    def prune_metrics
      cutoff = METRICS_RETENTION.ago
      ContainerMetric.where(sampled_at: ...cutoff).delete_all + HostMetric.where(sampled_at: ...cutoff).delete_all
    end

    # Only resolved alerts age out; a pending or firing one is live state, however old.
    def prune_alert_events
      AlertEvent.where(state: "resolved", resolved_at: ...RETENTION.ago).delete_all
    end

    def prune(model)
      keep_ids = latest_ids_per_group(model, model) | latest_ids_per_group(fallback_scope(model), model)

      model.where(observed_at: ...RETENTION.ago).where.not(id: keep_ids).delete_all
    end

    def fallback_scope(model)
      scope = model.where(reachable: true)
      scope = scope.where.not(container_name: nil) if model == Observation
      scope
    end

    def latest_ids_per_group(scope, model)
      latest_times = scope.group(*GROUP_BY).maximum(:observed_at)

      return [] if latest_times.empty?

      conditions = latest_times.map do |group_key, time|
        values = GROUP_BY.zip(Array(group_key))
        clause = values.map { |column, _| "#{column} = ?" }.join(" AND ")
        model.sanitize_sql([ "(#{clause} AND observed_at = ?)", *values.map(&:last), time ])
      end

      scope.where(conditions.join(" OR ")).pluck(:id)
    end
end
