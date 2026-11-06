module Alerting
  # The verdict on a resource-usage rule for one app, from the metrics rows CollectMetricsJob
  # writes once a minute (never SSH):
  #
  #   cpu_high          the mean CPU % of the app's containers over the last CPU_WINDOW ≥ threshold
  #   memory_high       any container's latest memory share ≥ threshold
  #   host_memory_high  any of the app's hosts' latest memory used ≥ threshold
  #   host_disk_high    any of the app's hosts' latest root disk used ≥ threshold
  #
  # for_minutes is the StateMachine's, as with every state rule: how long the verdict must keep
  # holding before it fires. CPU is still averaged over a few samples first, because one
  # `docker stats` reading covers about a second and is noisy; memory and disk move slowly and
  # read their latest sample.
  #
  # No sample within FRESH_WITHIN (no SSH key, hosts unreachable, collection stopped) is "can't
  # tell" (nil): it leaves an open alert as it is rather than resolving it on missing data.
  # kamal-proxy is left out: it is shared by every app on its host.
  class MetricCheck
    CPU_WINDOW = 3.minutes
    FRESH_WITHIN = 5.minutes

    def self.call(...) = new(...).call

    def initialize(rule, app, now: Time.current)
      @rule = rule
      @app = app
      @now = now
      @threshold = rule.metric_threshold.to_i
    end

    def call
      case rule.condition
      when "cpu_high" then cpu_high
      when "memory_high" then memory_high
      when "host_memory_high" then host_high("host_memory_high", &:mem_used_percent)
      when "host_disk_high" then host_high("host_disk_high", &:disk_used_percent)
      end
    end

    private
      attr_reader :rule, :app, :now, :threshold

      def containers = ContainerMetric.own.where(managed_app: app)

      # Mean over containers per sample, then over the samples in the window.
      def cpu_high
        per_sample = containers.where(sampled_at: (now - CPU_WINDOW)..now).where.not(cpu_percent: nil)
                               .group(:sampled_at).average(:cpu_percent).values
        return nil if per_sample.empty?

        mean = per_sample.sum.to_f / per_sample.size
        verdict(mean, "cpu_high", percent: mean.round(1))
      end

      def memory_high
        latest = containers.where(sampled_at: (now - FRESH_WITHIN)..now).where.not(mem_percent: nil)
                           .order(:sampled_at).to_a.index_by { |metric| [ metric.host, metric.container_name ] }.values
        return nil if latest.empty?

        worst = latest.max_by(&:mem_percent)
        verdict(worst.mem_percent, "memory_high", container: worst.container_name, host: worst.host,
                                                  percent: worst.mem_percent.round(1))
      end

      def host_high(message_key)
        latest = HostMetric.where(managed_app: app, host: app.parsed_config.all_hosts, sampled_at: (now - FRESH_WITHIN)..now)
                           .order(:sampled_at).to_a.index_by(&:host).values
        readings = latest.filter_map { |metric| (percent = yield(metric)) && [ metric.host, percent ] }
        return nil if readings.empty?

        host, percent = readings.max_by(&:last)
        verdict(percent, message_key, host:, percent: percent.round(1))
      rescue Kamal::ConfigParser::ParseError
        # Not polled since the config broke: the poll will record it; no hosts, no verdict.
        nil
      end

      def verdict(value, message_key, **args)
        value >= threshold ? Check.holds(message_key, **args, threshold:) : Check.clear
      end
  end
end
