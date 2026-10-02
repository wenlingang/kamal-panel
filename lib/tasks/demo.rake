# 一份"看得见的"演示数据：五个应用覆盖 ManagedAppStatus 的全部状态，外加两类
# 对账告警、两种来源的部署事件、三种结果的审计记录。
#
# 为什么值得进仓库：面板刚装好时是一片空白，而它的全部价值恰恰在"有东西不对时
# 长什么样"。克隆下来跑一条命令就能看到漂移、失联、容器异常、告警与审计，
# 比截图更可信，也比读文档快。
namespace :demo do
  desc "在开发环境灌入演示数据（五个应用，覆盖全部状态与告警）"
  task seed: :environment do
    # 这些数据会凭空造出"生产应用"和"部署记录"，在真实环境里是污染。
    unless Rails.env.development?
      abort "demo:seed 只在 development 下可用（当前是 #{Rails.env}）"
    end

    if ManagedApp.where("name LIKE ?", "demo-%").exists?
      # 审计日志按设计不可删除（见计划 02），所以没法"清掉旧的再来一遍"——
      # 重复播种只会让事件与审计翻倍。要重来就重建整个开发库。
      abort "已经有演示数据了。要重来请先 bin/rails db:reset 再执行本任务。"
    end

    admin = User.find_by(role: "admin")
    abort "先创建一个 admin：KAMAL_PANEL_ADMIN_EMAIL=... KAMAL_PANEL_ADMIN_PASSWORD=... bin/rails db:seed" if admin.nil?

    Demo::Seeder.new(admin).call
  end
end
