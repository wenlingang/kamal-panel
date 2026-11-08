require "yaml"

# How hard the panel probes managed hosts: config/collection.yml, overridden by the deployer (see
# that file for the layering). Loaded and validated once; a bad value fails loudly at boot.
#
#   settings = CollectionSettings.current
#   settings.status_idle                     # => 60.seconds
#   settings.for_host("10.0.0.5").containers # => false
class CollectionSettings
  class Error < StandardError; end

  DEFAULTS_PATH = Rails.root.join("config/collection.yml")
  LOCAL_OVERRIDE_PATH = Rails.root.join("storage/collection.yml")

  # section => key => validator. The single source of what exists: anything else is a typo.
  BOOLEAN = ->(value) { value == true || value == false }
  def self.seconds(range) = ->(value) { value.is_a?(Integer) && range.cover?(value) }

  SCHEMA = {
    "status" => {
      "tick" => seconds(1..60), "idle" => seconds(1..3600), "viewing" => seconds(1..3600),
      "burst" => seconds(1..3600), "proxy" => BOOLEAN
    },
    "metrics" => {
      "enabled" => BOOLEAN, "every" => seconds(1..60), "containers" => BOOLEAN, "spread" => seconds(0..55)
    },
    "log_scan" => { "enabled" => BOOLEAN },
    "alerts" => { "every" => seconds(10..600) }
  }.freeze

  # What a host may override; the rest only makes sense panel-wide (the scheduler ticks once for all).
  HOST_SCHEMA = {
    "status" => %w[proxy],
    "metrics" => %w[enabled every containers],
    "log_scan" => %w[enabled]
  }.freeze

  # One host's effective settings: the global values with that host's overrides on top.
  HostSettings = Data.define(:proxy, :metrics, :metrics_every, :containers, :log_scan) do
    # Samples are aligned to the clock: with every: 5 a host is sampled on minutes 0, 5, 10, ...
    def metrics_due?(sampled_at)
      metrics && (sampled_at.to_i / 60) % metrics_every == 0
    end
  end

  class << self
    def current
      @current ||= load
    end

    # Tests swap settings in and out; nil goes back to the files and ENV.
    attr_writer :current

    # The built-in values (config/collection.yml), before any override.
    def defaults = read_yaml(DEFAULTS_PATH)

    def load(env: ENV)
      config = defaults
      override = override_path(env)
      config = config.deep_merge(read_yaml(override)) if override
      new(apply_env(config, env))
    end

    private
      def override_path(env)
        if env["COLLECTION_CONFIG"].present?
          path = Pathname.new(env["COLLECTION_CONFIG"])
          raise Error, "COLLECTION_CONFIG 指向的文件不存在：#{path}" unless path.exist?

          path
        elsif LOCAL_OVERRIDE_PATH.exist?
          LOCAL_OVERRIDE_PATH
        end
      end

      def read_yaml(path)
        data = YAML.safe_load_file(path) || {}
        raise Error, "#{path} 的顶层必须是映射" unless data.is_a?(Hash)

        data
      rescue Psych::SyntaxError => e
        raise Error, "#{path} 不是合法的 YAML：#{e.message}"
      end

      # COLLECTION_<SECTION>_<KEY>, global values only. Parsed as YAML scalars, so "120" is an
      # Integer and "false" a boolean, the same as in the file.
      def apply_env(config, env)
        config = config.deep_dup
        SCHEMA.each do |section, keys|
          keys.each_key do |key|
            name = "COLLECTION_#{section}_#{key}".upcase
            next unless env.key?(name)

            (config[section] ||= {})[key] = YAML.safe_load(env[name].to_s)
          rescue Psych::SyntaxError
            raise Error, "环境变量 #{name} 的值无法解析：#{env[name].inspect}"
          end
        end
        config
      end
  end

  def initialize(config)
    @config = config
    validate!
    @host_settings = {}
  end

  def status_tick = seconds("status", "tick")
  def status_idle = seconds("status", "idle")
  def status_viewing = seconds("status", "viewing")
  def status_burst = seconds("status", "burst")
  def metrics_spread = seconds("metrics", "spread")
  def alerts_every = seconds("alerts", "every")

  def for_host(host)
    @host_settings[host.to_s] ||= begin
      own = host_overrides.fetch(host.to_s, {})
      pick = ->(section, key) { own.dig(section, key).then { |value| value.nil? ? @config.dig(section, key) : value } }

      HostSettings.new(
        proxy: pick.("status", "proxy"),
        metrics: pick.("metrics", "enabled"),
        metrics_every: pick.("metrics", "every"),
        containers: pick.("metrics", "containers"),
        log_scan: pick.("log_scan", "enabled")
      )
    end
  end

  private
    def seconds(section, key) = @config.dig(section, key).seconds

    # YAML may read a bare host key as something other than a String; deploy.yml hosts are Strings.
    def host_overrides
      hosts = @config["hosts"] || {}
      hosts.is_a?(Hash) ? hosts.transform_keys(&:to_s) : hosts
    end

    def validate!
      unknown = @config.keys - SCHEMA.keys - [ "hosts" ]
      raise Error, "采集配置里没有这些段：#{unknown.join(', ')}" if unknown.any?

      SCHEMA.each do |section, keys|
        values = @config[section]
        raise Error, "采集配置缺少 #{section} 段" unless values.is_a?(Hash)

        extra = values.keys - keys.keys
        raise Error, "采集配置 #{section} 段没有这些键：#{extra.join(', ')}" if extra.any?

        keys.each do |key, valid|
          raise Error, "采集配置 #{section}.#{key} 的值不合法：#{values[key].inspect}" unless valid.(values[key])
        end
      end

      validate_cadence!
      validate_hosts!
    end

    def validate_cadence!
      tick, burst, viewing, idle = %w[tick burst viewing idle].map { |key| @config.dig("status", key) }
      return if tick <= burst && burst <= viewing && viewing <= idle

      raise Error, "采集配置 status 的间隔必须满足 tick ≤ burst ≤ viewing ≤ idle" \
                   "（当前 #{tick} / #{burst} / #{viewing} / #{idle}）"
    end

    def validate_hosts!
      raise Error, "采集配置 hosts 必须是映射" unless host_overrides.is_a?(Hash)

      host_overrides.each do |host, sections|
        raise Error, "采集配置 hosts.#{host} 必须是映射" unless sections.is_a?(Hash)

        sections.each do |section, values|
          allowed = HOST_SCHEMA[section]
          raise Error, "采集配置 hosts.#{host} 不能覆盖 #{section} 段" unless allowed
          raise Error, "采集配置 hosts.#{host}.#{section} 必须是映射" unless values.is_a?(Hash)

          values.each do |key, value|
            raise Error, "采集配置 hosts.#{host}.#{section} 不能覆盖 #{key}" unless allowed.include?(key)
            raise Error, "采集配置 hosts.#{host}.#{section}.#{key} 的值不合法：#{value.inspect}" unless SCHEMA[section][key].(value)
          end
        end
      end
    end
end
