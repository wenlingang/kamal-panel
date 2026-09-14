# Kamal 命名空间下的值对象。不落库——deploy.yml 是唯一真相，
# 解析结果每次现算（spec 5.1）。
class Kamal::ParsedConfig
  attr_reader :service, :destination, :roles, :app_hosts, :primary_host,
              :registry_server, :registry_password_env, :ssh_options

  def initialize(attributes)
    @service               = attributes.fetch("service")
    @destination           = attributes["destination"]
    @roles                 = attributes.fetch("roles").map(&:symbolize_keys)
    @app_hosts             = attributes.fetch("app_hosts")
    @primary_host          = attributes["primary_host"]
    @registry_server       = attributes["registry_server"]
    @registry_password_env = attributes["registry_password_env"]
    @ssh_options           = attributes.fetch("ssh_options").symbolize_keys
  end

  def role_names
    roles.map { |role| role[:name] }
  end

  def container_prefix_for(role_name)
    roles.detect { |role| role[:name] == role_name.to_s }&.fetch(:container_prefix)
  end
end
