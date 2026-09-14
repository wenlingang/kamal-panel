# 手动触发一次采集。
#
# 与 ActionsController 的关键区别：这是【读】动作。不取部署锁、不写审计、
# 不要求动作权限——面板本来就在自动采集，这个按钮只是让下一轮提前发生。
# spec 7.7 的"没权限就看不到按钮"针对的是会改变线上状态的写操作，所以这里
# 有意不挂任何授权过滤器：三档角色都能用。
#
# 也不额外限流：连点的代价已经被 PollCadence 吸收——burst 档就是 2 秒一轮，
# 重复入队不会让它更快。真要防滥用应该在 PollCadence 里做，而不是在这里
# 贴一层补丁。
class RefreshesController < ApplicationController
  def create
    managed_app = ManagedApp.find(params[:managed_app_id])

    PollCadence.mark_burst!(managed_app)
    PollManagedAppJob.perform_later(managed_app)

    respond_to do |format|
      # 立刻把区块换成"正在采集"，真实结果由 PollManagedAppJob 的广播覆盖
      # 回来——所以这一步不刷整页。
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "host-status",
          partial: "managed_apps/refreshing"
        )
      end
      format.html { redirect_to managed_app }
    end
  end
end
