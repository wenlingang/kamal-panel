# A value object under the Kamal namespace.
# The parse result is computed fresh every time (spec 5.1).
class Kamal::ParsedConfig
  attr_reader :service, :destination, :roles, :app_hosts, :primary_host,
              :registry_server, :registry_password_env, :registry_username, :ssh_options,
              :image, :repository, :accessories

  def initialize(attributes)
    @service               = attributes.fetch("service")
    @destination           = attributes["destination"]
    @roles                 = attributes.fetch("roles").map(&:symbolize_keys)
    @app_hosts             = attributes.fetch("app_hosts")
    @primary_host          = attributes["primary_host"]
    @registry_server       = attributes["registry_server"]
    @registry_password_env = attributes["registry_password_env"]
    # Literal usernames only (nil for a secret reference); read by RegistryProbe.
    @registry_username     = attributes["registry_username"]
    @ssh_options           = attributes.fetch("ssh_options").symbolize_keys
    # "org/app": the repository path inside the registry, without the server.
    @image                 = attributes["image"]
    # "registry.example.com/org/app": registry server + image, what `docker pull` takes.
    @repository            = attributes["repository"]
    # [{ name:, hosts:, image:, container_name: }]
    @accessories           = Array(attributes["accessories"]).map(&:symbolize_keys)
  end

  def role_names
    roles.map { |role| role[:name] }
  end

  def container_prefix_for(role_name)
    roles.detect { |role| role[:name] == role_name.to_s }&.fetch(:container_prefix)
  end

  def accessory_names
    accessories.map { |accessory| accessory[:name] }
  end

  def accessory(name)
    accessories.detect { |accessory| accessory[:name] == name.to_s }
  end

  # The proxy settings of one role ({ hosts:, ssl:, path_prefixes: }), nil when it runs without
  # kamal-proxy.
  def proxy_for(role)
    proxy = role[:proxy]
    return nil unless proxy.is_a?(Hash)

    { hosts: Array(proxy["hosts"]), ssl: proxy["ssl"] == true, path_prefixes: Array(proxy["path_prefixes"]) }
  end

  # The domains kamal-proxy routes to this app, from proxy.hosts / proxy.host of every role:
  # [{ host: "app.example.com", ssl: true, roles: ["web"] }], in config order.
  def domains
    roles.each_with_object({}) do |role, by_host|
      proxy = proxy_for(role) or next

      proxy[:hosts].each do |host|
        entry = by_host[host] ||= { host: host, ssl: false, roles: [] }
        entry[:ssl] ||= proxy[:ssl]
        entry[:roles] << role[:name]
      end
    end.values
  end

  # Every host Kamal's commands without --hosts touch: app roles plus accessories (KAMAL.hosts).
  def all_hosts
    (app_hosts + accessories.flat_map { |accessory| Array(accessory[:hosts]) }).uniq
  end
end
