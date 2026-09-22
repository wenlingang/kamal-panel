# 生成 / 重置上报 token。
class HookTokensController < ApplicationController
  def create
    app = ManagedApp.find(params[:managed_app_id])
    require_permission!(:regenerate_hook_token, app)
    return if performed?

    token = app.regenerate_hook_token!

    redirect_to app, flash: { hook_token: token }
  end
end
