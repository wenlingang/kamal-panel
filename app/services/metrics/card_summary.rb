module Metrics
  # The overview card's one metrics line: this app's containers (not the shared kamal-proxy) summed
  # at their latest minute — "CPU 12% · memory 340 MiB" — plus the last hour of that CPU total for
  # a sparkline. One query for every card on the page; never SSH.
  class CardSummary
    SPAN = 1.hour
    Summary = Data.define(:cpu_percent, :mem_bytes, :sampled_at, :cpu_points)

    # { app_id => Summary }; apps without a recent sample are absent (the card then shows nothing).
    def self.for(apps, now: Time.current)
      ids = apps.map(&:id)
      return {} if ids.empty?

      rows = ContainerMetric.own.where(managed_app_id: ids, sampled_at: (now - SPAN)..now)
                            .group(:managed_app_id, :sampled_at).order(:sampled_at)
                            .pluck(:managed_app_id, :sampled_at, Arel.sql("SUM(cpu_percent)"), Arel.sql("SUM(mem_bytes)"))

      rows.group_by(&:first).filter_map do |app_id, app_rows|
        _, at, cpu, mem = app_rows.last
        next if at < now - AppMetrics::LATEST_WITHIN

        [ app_id, Summary.new(cpu_percent: cpu&.to_f, mem_bytes: mem&.to_i, sampled_at: at,
                              cpu_points: app_rows.map { |_, time, value, _| [ time, value&.to_f ] }) ]
      end.to_h
    end
  end
end
