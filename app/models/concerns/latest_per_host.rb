# Observation and ProxyTarget each take their latest row per (managed_app, host).
# In plan 01 this query had two copies; they behaved the same but would diverge.
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
