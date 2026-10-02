# 仓库里那份 config/deploy.yml 是给人照抄的范例（README「Deploying the panel
# itself」）。它写坏了、或者 Kamal 升级之后不再接受它，我们应当比读者先知道——
# 所以让 CI 拿【面板自己的解析器】解一遍：与面板处理用户粘贴的 deploy.yml
# 走的是同一条代码路径，不是另写一份"差不多"的校验。
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
