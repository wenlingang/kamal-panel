# Observation 与 ProxyTarget 都按 (managed_app, host) 取各自最新一行。
# 计划 01 中这段查询有两份副本；行为一致但会分叉。
module LatestPerHost
  extend ActiveSupport::Concern

  class_methods do
    def latest_for(managed_app)
      latest_times = where(managed_app: managed_app).group(:host).maximum(:observed_at)
      return none if latest_times.empty?

      conditions = latest_times.map { |host, time|
        sanitize_sql([ "(host = ? AND observed_at = ?)", host, time ])
      }

      where(managed_app: managed_app).where(conditions.join(" OR "))
    end
  end
end
