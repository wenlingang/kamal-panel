# 手动触发一次采集。
class RefreshesController < ApplicationController
  def create
    managed_app = ManagedApp.find(params[:managed_app_id])

    PollCadence.mark_burst!(managed_app)
    PollManagedAppJob.perform_later(managed_app)

    respond_to do |format|
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
