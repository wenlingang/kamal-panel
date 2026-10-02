# 部署锁状态。只读，三档角色都能看——它决定的是"现在能不能动这个应用"。
class LocksController < ApplicationController
  def show
    @managed_app = ManagedApp.find(params[:managed_app_id])
    require_permission!(:show, @managed_app)
    return if performed?

    render layout: false
  end
end
