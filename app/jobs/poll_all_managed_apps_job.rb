# 由 Solid Queue 的 recurring 定时触发。
# 每个应用按自己的节奏决定这一轮是否该跑（spec 6.3）。
class PollAllManagedAppsJob < ApplicationJob
  queue_as :default

  def perform
    # 停用的应用不再采集：它没有凭据了（停用会释放绑定），继续采只会每轮
    # 攒一条失败观测。
    ManagedApp.active.find_each do |managed_app|
      PollManagedAppJob.perform_later(managed_app) if claim_slot!(managed_app)
    end
  end

  private
    # 用 unless_exist 的原子写来"认领"这一轮——而不是先读 last_run 再写。
    # 先读后写在多线程/多次调度重叠时会两边都判断为"到点了"，导致同一个应用
    # 被双倍轮询（双倍 SSH 扇出），恰好抵消了自适应节奏本该省下的成本。
    #
    # 认领的 TTL 直接用这一刻的节奏间隔：认领到期，下一次调度自然又能认领，
    # 这就是"到点了"。缓存条目随时可能被驱逐——驱逐等价于"从没跑过"，
    # 下一次调度必须能认领成功（立即轮询），而不是永远认领不到。
    def claim_slot!(managed_app)
      Rails.cache.write(
        PollCadence.last_run_key(managed_app),
        Time.current,
        expires_in: PollCadence.interval_for(managed_app),
        unless_exist: true
      )
    end
end
