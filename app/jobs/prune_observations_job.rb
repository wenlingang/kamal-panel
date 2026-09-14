# 清理过期的观测快照。
#
# Observation / ProxyTarget 只追加，因此必须有清理（spec 5.2）。
#
# 但每台主机必须留下两条锚点，而不是一条：
#
#   1. 全局最近一条（不论 reachable）——用于判断"这台机器最近一次
#      发生了什么"。
#   2. 最近一条 reachable: true 的记录——这是失联呈现（spec 6.4）
#      唯一能回退到的"上次已知状态"。
#
# 只保留 (1) 是不够的：一台机器失联超过保留期后，"全局最近一条"
# 恰好就是那条不可达记录，而它能回退到的、真正有用的历史——最近
# 一次可达——比它更旧，会被当成"过期数据"删掉。于是失联时间越长的
# 机器，越先失去历史，面板会从"上次已知状态"退化成"无可用的历史
# 状态"，而这恰恰是失联呈现最需要撑住的场景（见
# test/jobs/prune_observations_job_test.rb 里"主机失联超过保留期"
# 的测试——针对只保留(1)的实现，这个测试会失败）。
#
# ProxyTarget 现在同样带 reachable 字段，所以同样的两条锚点规则也
# 适用于它。
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

    # 保留条件必须跟"回退真正会读到什么"完全一致，否则 prune 可能保留一条
    # 回退用不上的行、删掉唯一有用的那条（见 final review I6/M3）：
    # ManagedAppStatus#last_reachable_observation 要的是"最新一条可达
    # **且带容器**的 Observation"，不是随便一条可达的——一台机器容器被
    # 清空但仍可达的那一行对回退毫无用处。ProxyTarget 没有"容器"这个概念，
    # 继续保留"最新一条可达"就是它的回退真正会用到的那一条。
    def fallback_scope(model)
      scope = model.where(reachable: true)
      scope = scope.where.not(container_name: nil) if model == Observation
      scope
    end

    # 跟 Observation.latest_for 同样的写法：group().maximum() 拿到每个
    # 分组的边界时间，再拼成一条 OR 连接的 SQL 一次性查出所有符合条件的
    # id——而不是按分组数量发起同样多次查询。行为不变，只是跟仓库里
    # 其他地方处理"每个分组最近一条"的方式保持一致（review：per-group
    # 查询是按分组数而不是行数增长，不是性能风险，但下一个读这段代码
    # 的人会照抄先看到的那种写法，所以统一）。
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
