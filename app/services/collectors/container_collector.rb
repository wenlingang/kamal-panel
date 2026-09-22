require "json"
require "shellwords"

module Collectors
  # 每个 ManagedApp × 每台 host 一条命令，取回该应用的全部容器。
  class ContainerCollector
    # docker ps 通了、但每一行都读不懂时写进 observations.error 的那句话。
    UNPARSEABLE_OUTPUT_MARKER = "输出无法解析".freeze

    def self.unparseable_output_error(line_count)
      "docker ps #{UNPARSEABLE_OUTPUT_MARKER}（#{line_count} 行全部解析失败），详情见日志"
    end

    # label 被压平成逗号拼接后无法可靠反切分，而 service/destination 没有字符集限制。
    DOCKER_FORMAT_TEMPLATE = '{"name":{{json .Names}},"state":{{json .State}},' \
                             '"status":{{json .Status}},"role":{{json (.Label "role")}},' \
                             '"destination":{{json (.Label "destination")}}}'

    def self.call(managed_app)
      new(managed_app).call
    end

    def initialize(managed_app)
      @managed_app = managed_app
      @observed_at = Time.current
    end

    def call
      rows = []

      results.each do |host, result|
        rows.concat(
          if result.error
            [ unreachable_row(host, result.error) ]
          else
            container_rows(host, result.stdout)
          end
        )
      end

      Observation.insert_all!(rows) if rows.any?
      rows.size
    end

    private
      attr_reader :managed_app, :observed_at

      def results
        SshSession.new(managed_app).capture_many(managed_app.app_hosts) { docker_ps_command }
      end

      def docker_ps_command
        filters = [ "label=service=#{Shellwords.escape(managed_app.service)}" ]

        if managed_app.destination.present?
          filters << "label=destination=#{Shellwords.escape(managed_app.destination)}"
        end

        [
          "docker ps --all",
          *filters.map { |f| "--filter #{f}" },
          "--format #{Shellwords.escape(DOCKER_FORMAT_TEMPLATE)}"
        ].join(" ")
      end

      def container_rows(host, stdout)
        lines = stdout.to_s.lines.map(&:strip).reject(&:blank?)

        return [ empty_row(host) ] if lines.empty?

        rows = lines.filter_map { |line| container_row(host, line) }

        return [ unparseable_row(host, lines.size) ] if rows.empty?

        rows
      end

      def container_row(host, line)
        data = JSON.parse(line)
        name = data["name"].to_s
        role = data["role"].presence
        destination = data["destination"].presence

        base_row(host).merge(
          role: role,
          container_name: name,
          version: extract_version(name, role, destination),
          docker_status: data["state"],
          health: extract_health(data["status"])
        )
      rescue JSON::ParserError => e
        Rails.logger.error(
          "[Collectors::ContainerCollector] managed_app_id=#{managed_app.id} host=#{host} " \
          "无法解析 docker ps 输出的一行（#{e.class}，长度 #{line.to_s.bytesize} 字节），已跳过该行"
        )
        nil
      end

      def extract_version(name, role, destination)
        prefix = [ managed_app.service, role, destination ].compact.join("-")
        return nil unless name.start_with?("#{prefix}-")

        name.delete_prefix("#{prefix}-")
      end

      def extract_health(status)
        status.to_s[/\((healthy|unhealthy|health: starting)\)/, 1]
      end

      def base_row(host)
        { managed_app_id: managed_app.id, host: host, reachable: true,
          observed_at: observed_at, created_at: observed_at }
      end

      def empty_row(host)
        base_row(host)
      end

      def unreachable_row(host, error)
        base_row(host).merge(reachable: false, error: error.truncate(255))
      end

      def unparseable_row(host, line_count)
        base_row(host).merge(reachable: false,
                             error: self.class.unparseable_output_error(line_count))
      end
  end
end
