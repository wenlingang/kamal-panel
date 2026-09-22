# 清理过期的观测快照。Observation / ProxyTarget 只追加，必须有清理。
# 每台主机留【两条】锚点：全局最近一条，以及最近一条 reachable——只留前者，失联越久越先失去历史。
class PruneObservationsJob < ApplicationJob
  queue_as :default

  RETENTION = 14.days
  GROUP_BY = [ :managed_app_id, :host ].freeze

  def perform
    prune(Observation) + prune(ProxyTarget)
  end

  private
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
