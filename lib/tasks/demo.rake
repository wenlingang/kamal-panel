# A "visible" demo data set: five apps covering every ManagedAppStatus state, plus two kinds of
# reconciliation alerts, deploy events from two sources, and audit records with three kinds of
# results.
#
# Why it's worth keeping in the repo: a freshly installed panel is blank, and all of its value lies
# in "what it looks like when something is wrong". Clone it, run one command, and you see drift,
# unreachable hosts, container failures, alerts and audits; more convincing than screenshots, and
# faster than reading docs.
namespace :demo do
  desc "在开发环境灌入演示数据（五个应用，覆盖全部状态与告警）"
  task seed: :environment do
    # This data fabricates "production apps" and "deploy records" out of thin air, which is
    # pollution in a real environment.
    unless Rails.env.development?
      abort "demo:seed 只在 development 下可用（当前是 #{Rails.env}）"
    end

    if ManagedApp.where("name LIKE ?", "demo-%").exists?
      # Audit logs are undeletable by design (see plan 02), so there is no "clear the old ones and
      # start over": re-seeding would only double the events and audits. To start over, rebuild the
      # whole development database.
      abort "已经有演示数据了。要重来请先 bin/rails db:reset 再执行本任务。"
    end

    admin = User.find_by(role: "admin")
    abort "先创建一个 admin：KAMAL_PANEL_ADMIN_EMAIL=... KAMAL_PANEL_ADMIN_PASSWORD=... bin/rails db:seed" if admin.nil?

    Demo::Seeder.new(admin).call
  end
end
