module Metrics
  # What the metrics tab shows for one app: series bucketed in SQL over a TimeRange, and the latest
  # sample of each container and host. Reads rows only, never SSH; the hosts come from the parsed
  # config, so callers must not build one for an app whose config doesn't parse.
  class AppMetrics
    # A sample older than this is not "current": the table says so instead of showing it as now.
    LATEST_WITHIN = 5.minutes
    KIND_ORDER = ContainerMetric::KINDS

    Series = Data.define(:key, :label, :points) do
      def values = points.map(&:last).compact
      def latest = points.reverse_each.find { |_, value| !value.nil? }&.last
    end

    attr_reader :managed_app, :range

    def initialize(managed_app, range: TimeRange.new(nil), hosts: nil)
      @managed_app = managed_app
      @range = range
      @hosts = hosts
    end

    def hosts = @hosts ||= managed_app.parsed_config.all_hosts

    def any_data?
      container_buckets.any? || host_buckets.any?
    end

    # One line per role / accessory / proxy per host: "web @ 10.1.0.11".
    def container_cpu_series = container_series(:cpu)
    def container_mem_series = container_series(:mem)

    # The highest memory limit seen per series in the range (nil when none has one).
    def container_mem_limits
      container_buckets.group_by { |row| row[:key] }.filter_map do |key, rows|
        limit = rows.filter_map { |row| row[:mem_limit] }.max
        [ key, limit ] if limit
      end.to_h
    end

    # { host => { load1:, cpus:, cpu:, mem:, disk: } series }, every host of the config, in order.
    def host_series
      by_host = host_buckets.group_by { |row| row[:host] }
      hosts.index_with do |host|
        rows = by_host.fetch(host, [])
        %i[load1 cpus cpu mem disk].index_with do |metric|
          Series.new(key: "#{host}/#{metric}", label: metric.to_s,
                     points: rows.map { |row| [ row[:time], row[metric] ] })
        end
      end
    end

    # The newest sample of every container seen in the last LATEST_WITHIN, sorted for the table.
    def latest_containers
      ContainerMetric.where(managed_app: managed_app, sampled_at: (range.to - LATEST_WITHIN)..)
                     .order(:sampled_at).to_a
                     .index_by { |metric| [ metric.host, metric.container_name ] }.values
                     .sort_by { |metric| [ KIND_ORDER.index(metric.kind), metric.source, metric.host ] }
    end

    # { host => HostMetric or nil }, in config order.
    def latest_hosts
      latest = HostMetric.where(managed_app: managed_app, host: hosts, sampled_at: (range.to - LATEST_WITHIN)..)
                         .order(:sampled_at).to_a.index_by(&:host)
      hosts.index_with { |host| latest[host] }
    end

    private
      def container_series(metric)
        container_buckets.group_by { |row| row[:key] }
                         .sort_by { |key, rows| [ KIND_ORDER.index(rows.first[:kind]), key ] }
                         .map do |key, rows|
          Series.new(key:, label: rows.first[:label], points: rows.map { |row| [ row[:time], row[metric] ] })
        end
      end

      # One row per (host, source, bucket), ordered by time. Averages within a bucket; while a
      # deploy runs old and new containers side by side, that is their mean.
      def container_buckets
        @container_buckets ||= begin
          bucket = range.bucket_sql
          ContainerMetric.where(managed_app: managed_app, sampled_at: range.from..range.to)
                         .group(:host, :source, :kind, Arel.sql(bucket))
                         .order(Arel.sql(bucket))
                         .pluck(:host, :source, :kind, Arel.sql(bucket), Arel.sql("AVG(cpu_percent)"),
                                Arel.sql("AVG(mem_bytes)"), Arel.sql("MAX(mem_limit_bytes)"))
                         .map do |host, source, kind, slot, cpu, mem, limit|
            { key: "#{source}@#{host}", label: "#{source} @ #{host}", kind:, host:,
              time: range.bucket_time(slot), cpu: cpu&.to_f, mem: mem&.to_f, mem_limit: limit }
          end
        end
      end

      def host_buckets
        @host_buckets ||= begin
          bucket = range.bucket_sql
          HostMetric.where(managed_app: managed_app, host: hosts, sampled_at: range.from..range.to)
                    .group(:host, Arel.sql(bucket))
                    .order(Arel.sql(bucket))
                    .pluck(:host, Arel.sql(bucket), Arel.sql("AVG(load1)"), Arel.sql("MAX(cpus)"),
                           Arel.sql("AVG(cpu_percent)"),
                           Arel.sql("AVG(100.0 * (mem_total_bytes - mem_available_bytes) / mem_total_bytes)"),
                           Arel.sql("AVG(100.0 * disk_used_bytes / disk_total_bytes)"))
                    .map do |host, slot, load1, cpus, cpu, mem, disk|
            { host:, time: range.bucket_time(slot), load1: load1&.to_f, cpus: cpus&.to_f,
              cpu: cpu&.to_f, mem: mem&.to_f, disk: disk&.to_f }
          end
        end
      end
  end
end
