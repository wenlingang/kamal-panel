require "shellwords"

module Collectors
  # One metrics round for one app (CollectMetricsJob, once a minute): a single SSH command per
  # host (every host of the config, accessory hosts included, that is due under metrics.* in
  # config/collection.yml) that prints, between markers,
  #
  #   docker stats   — every running container; this app's are picked out by name below
  #   /proc/loadavg, nproc, /proc/meminfo, the "cpu" line of /proc/stat, df -P -k /
  #
  # Host CPU % is not sampled twice within the command (that would hold the SSH session open for
  # a second per host): the raw /proc/stat jiffies are stored, and the busy share is the delta
  # against the previous stored sample of the same host, about a minute earlier.
  #
  # A host that can't be reached, or prints nothing usable, records nothing: a gap in the chart
  # says "no data" more honestly than a zero. Reachability is the status collector's business.
  class MetricsCollector
    MARKER = "::kamal-panel-metrics::".freeze
    SECTIONS = %w[stats loadavg nproc meminfo stat df].freeze

    # docker stats --no-stream waits for a second sample of every container (~1–2 s), more on a
    # busy host; the status collector's 15 s budget is for a plain `docker ps`.
    EXECUTION_TIMEOUT = 30

    # Previous /proc/stat reading older than this is not a meaningful "last minute".
    CPU_DELTA_MAX_AGE = 10.minutes

    PROXY_CONTAINER = "kamal-proxy".freeze

    HOST_COLUMNS = %i[load1 load5 load15 cpus cpu_percent cpu_total_jiffies cpu_idle_jiffies
                      mem_total_bytes mem_available_bytes swap_total_bytes swap_free_bytes
                      disk_total_bytes disk_used_bytes].freeze

    def self.call(...) = new(...).call

    def initialize(managed_app, now: Time.current, ssh: nil)
      @managed_app = managed_app
      # One timestamp per round, truncated to the minute: the unique indexes then make a repeated
      # round in the same minute a no-op instead of a double sample.
      @sampled_at = now.change(sec: 0)
      @ssh = ssh
    end

    # Returns { containers: n, hosts: n } rows written.
    def call
      container_rows = []
      host_rows = []

      results.each do |host, result|
        next if result.error

        sections = self.class.split_sections(result.stdout)
        host_row = host_row(host, sections)
        host_rows << host_row if host_row
        container_rows.concat(container_rows_for(host, sections["stats"], host_row&.dig(:mem_total_bytes)))
      end

      ContainerMetric.insert_all(container_rows) if container_rows.any?
      HostMetric.insert_all(host_rows) if host_rows.any?
      { containers: container_rows.size, hosts: host_rows.size }
    end

    # containers: false (metrics.containers in config/collection.yml) leaves out `docker stats`, the
    # one part that costs the host something: dockerd samples every running container for it.
    def self.command(containers: true)
      SECTIONS.zip([
        "docker stats --no-stream --format #{Shellwords.escape('{{json .}}')} 2>&1",
        "cat /proc/loadavg",
        "nproc",
        "grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo",
        "head -n 1 /proc/stat",
        "df -P -k /"
      ]).reject { |name, _| name == "stats" && !containers }
        .map { |name, cmd| "echo '#{MARKER}#{name}'; #{cmd}" }.join("; ")
    end

    # { "stats" => "...", "loadavg" => "...", ... }; a section the host never reached is absent.
    def self.split_sections(stdout)
      sections = {}
      current = nil
      stdout.to_s.each_line do |line|
        if line.start_with?(MARKER)
          current = line.delete_prefix(MARKER).strip
          sections[current] = +""
        elsif current
          sections[current] << line
        end
      end
      sections
    end

    private
      attr_reader :managed_app, :sampled_at

      def config = managed_app.parsed_config

      # Only the hosts due this minute (metrics.enabled / metrics.every, per host); none due, no SSH.
      def results
        hosts = config.all_hosts.select { |host| settings_for(host).metrics_due?(sampled_at) }
        return {} if hosts.empty?

        (@ssh || SshSession.new(managed_app, execution_timeout: EXECUTION_TIMEOUT))
          .capture_many(hosts) { |host| self.class.command(containers: settings_for(host).containers) }
      end

      def settings_for(host) = CollectionSettings.current.for_host(host)

      # ── Containers ──────────────────────────────────────────────────────────────────

      def container_rows_for(host, text, host_mem_total)
        lines = text.to_s.lines.map(&:strip).reject(&:blank?)
        parsed = lines.filter_map { |line| Metrics::Parsing.docker_stats_line(line) }
        log_docker_error(host, lines) if parsed.empty? && lines.any?

        parsed.filter_map do |stats|
          identity = identify(stats[:name])
          next unless identity

          base_row(host).merge(stats.except(:name), identity, container_name: stats[:name],
                               mem_limit_bytes: real_limit(stats[:mem_limit_bytes], host_mem_total))
        end
      end

      # Which part of this app a container is, by Kamal's naming: accessories by their exact
      # container name, app containers by "<service>-<role>[-<destination>]-<version>", plus the
      # host's kamal-proxy. Anything else belongs to someone else.
      def identify(name)
        return { kind: "proxy", source: PROXY_CONTAINER, version: nil } if name == PROXY_CONTAINER

        accessory = config.accessories.find { |entry| entry[:container_name] == name }
        return { kind: "accessory", source: accessory[:name], version: nil } if accessory

        role = roles_longest_prefix_first.find { |entry| name.start_with?("#{entry[:container_prefix]}-") }
        return nil unless role

        { kind: "app", source: role[:name], version: name.delete_prefix("#{role[:container_prefix]}-") }
      end

      # "blog-web" must not claim "blog-web-api-…" when a role named "web-api" exists.
      def roles_longest_prefix_first
        @roles_longest_prefix_first ||= config.roles.sort_by { |role| -role[:container_prefix].to_s.length }
      end

      # Without a limit docker reports the host's memory as the limit; store nil then, so the chart
      # draws a limit line only for containers that have one. The two differ by docker's rounding
      # to four significant figures.
      def real_limit(limit, host_mem_total)
        return limit if limit.nil? || host_mem_total.nil?

        limit >= host_mem_total * 0.995 ? nil : limit
      end

      def log_docker_error(host, lines)
        Rails.logger.warn(
          "[Collectors::MetricsCollector] managed_app_id=#{managed_app.id} host=#{host} " \
          "docker stats 没有可解析的输出：#{lines.first.to_s.truncate(200)}"
        )
      end

      def base_row(host)
        { managed_app_id: managed_app.id, host: host, sampled_at: sampled_at }
      end

      # ── Host ───────────────────────────────────────────────────────────────────────

      def host_row(host, sections)
        values = HOST_COLUMNS.index_with(nil)
        values.merge!(Metrics::Parsing.loadavg(sections["loadavg"]))
        values[:cpus] = Metrics::Parsing.integer(sections["nproc"])
        values.merge!(Metrics::Parsing.meminfo(sections["meminfo"]))
        values.merge!(Metrics::Parsing.proc_stat(sections["stat"]))
        values.merge!(Metrics::Parsing.df(sections["df"]))
        # A host that printed none of it (not Linux, the command cut short) has no sample.
        return nil if values.except(:cpus).values.all?(&:nil?)

        values[:cpu_percent] = Metrics::Parsing.cpu_percent_between(previous_jiffies(host), values)
        # Every row carries every column: insert_all wants the same keys in each.
        { managed_app_id: managed_app.id, host: host, sampled_at: sampled_at }.merge(values)
      end

      def previous_jiffies(host)
        # A host sampled every N minutes has its previous reading N minutes back.
        max_age = [ CPU_DELTA_MAX_AGE, 2 * settings_for(host).metrics_every.minutes ].max
        HostMetric.where(managed_app: managed_app, host: host, sampled_at: (sampled_at - max_age)...sampled_at)
                  .where.not(cpu_total_jiffies: nil)
                  .order(sampled_at: :desc)
                  .pick(:cpu_total_jiffies, :cpu_idle_jiffies)
                  &.then { |total, idle| { cpu_total_jiffies: total, cpu_idle_jiffies: idle } }
      end
  end
end
