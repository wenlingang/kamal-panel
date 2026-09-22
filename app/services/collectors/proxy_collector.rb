require "json"

module Collectors
  class ProxyCollector
    COMMAND = "docker exec kamal-proxy kamal-proxy list --json".freeze

    def self.call(managed_app)
      new(managed_app).call
    end

    def initialize(managed_app)
      @managed_app = managed_app
      @observed_at = Time.current
    end

    def call
      rows = results.flat_map { |host, result| rows_for(host, result) }

      ProxyTarget.insert_all!(rows) if rows.any?
      rows.size
    end

    private
      attr_reader :managed_app, :observed_at

      def results
        SshSession.new(managed_app).capture_many(managed_app.app_hosts) { COMMAND }
      end

      def rows_for(host, result)
        return [ unreachable_row(host, result.error) ] if result.error
        return [ empty_row(host) ] if result.stdout.blank?

        parsed = safe_parse(json_payload(result.stdout))

        return [ unrecognized_row(host, result.stdout) ] unless recognized_shape?(parsed)

        entries = entries_for(parsed).select { |entry| belongs_to_this_app?(entry) }

        return [ empty_row(host) ] if entries.empty?

        entries.map { |entry| row(host, entry) }
      end

      # kamal-proxy 在 happy path 上偶尔会往 stderr 写一行（已合并进 stdout）。
      def json_payload(stdout)
        text = stdout.to_s
        start = text.index("{") || text.index("[")
        start ? text[start..] : text
      end

      def safe_parse(stdout)
        JSON.parse(stdout)
      rescue JSON::ParserError
        nil
      end

      # 顶层形状必须是 Hash 或 Array 才认为「认识」；
      def recognized_shape?(parsed)
        parsed.is_a?(Hash) || parsed.is_a?(Array)
      end

      def entries_for(parsed)
        case parsed
        when Hash  then parsed.map { |name, value| { name: name, value: value } }
        when Array then parsed.map { |value| { name: nil, value: value } }
        end
      end

      def belongs_to_this_app?(entry)
        name = service_name_of(entry).to_s
        return false if name.blank?

        container_prefixes.include?(name)
      end

      def container_prefixes
        managed_app.parsed_config.roles.map { |role| role[:container_prefix] }
      end

      def service_name_of(entry)
        return entry[:name] if entry[:name].present?

        value = entry[:value]
        return nil unless value.is_a?(Hash)

        value["service"] || value["Service"] || value["name"] || value["Name"]
      end

      def target_of(entry)
        value = entry[:value]
        return nil unless value.is_a?(Hash)

        value["targets"] || value["Targets"] || value["target"] || value["Target"] ||
          value["hosts"] || value["Hosts"]
      end

      def state_of(entry)
        value = entry[:value]
        return nil unless value.is_a?(Hash)

        value["state"] || value["State"]
      end

      def row(host, entry)
        base_row(host).merge(
          service_name: service_name_of(entry),
          target: Array(target_of(entry)).join(", ").presence,
          state: state_of(entry),
          raw: raw_json(entry)
        )
      end

      def raw_json(entry)
        entry[:name] ? JSON.generate({ entry[:name] => entry[:value] }) : JSON.generate(entry[:value])
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

      def unrecognized_row(host, stdout)
        base_row(host).merge(raw: stdout.to_s.truncate(10_000))
      end
  end
end
