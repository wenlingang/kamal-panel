# The config/deploy.yml in the repo is a sample meant to be copied by people (README "Deploying the
# panel itself"). If it's broken, or Kamal stops accepting it after an upgrade, we should know
# before our readers do, so have CI run it through [the panel's own parser]: it takes the same code
# path as the panel handling a user-pasted deploy.yml, rather than a separate "roughly equivalent"
# validation.
namespace :deploy_config do
  desc "用面板自己的解析器校验仓库内的 config/deploy.yml"
  task verify: :environment do
    path = Rails.root.join("config/deploy.yml")
    config = Kamal::ConfigParser.call(yaml: path.read)

    puts "config/deploy.yml 解析通过"
    puts "  service:  #{config.service}"
    puts "  roles:    #{config.role_names.join(', ')}"
    puts "  hosts:    #{config.app_hosts.join(', ')}"
    puts "  registry: #{config.registry_server}"
  rescue Kamal::ConfigParser::ParseError => e
    abort "config/deploy.yml 解析失败：#{e.message}"
  end
end
