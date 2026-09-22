# 由 Solid Queue 的 recurring 定时触发。
# 每个应用按自己的节奏决定这一轮是否该跑（spec 6.3）。
class PollAllManagedAppsJob < ApplicationJob
  queue_as :default

  def perform
    # 攒一条失败观测。
    ManagedApp.active.find_each do |managed_app|
      PollManagedAppJob.perform_later(managed_app) if claim_slot!(managed_app)
    end
  end

  private
    # 用 unless_exist 的原子写来"认领"这一轮——而不是先读 last_run 再写。
    def claim_slot!(managed_app)
      Rails.cache.write(
        PollCadence.last_run_key(managed_app),
        Time.current,
        expires_in: PollCadence.interval_for(managed_app),
        unless_exist: true
      )
    end
end
