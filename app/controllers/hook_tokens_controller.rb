# 生成 / 重置上报 token。
#
# 明文只在这一次的 flash 里出现，不落库、不再展示第二次——
# 与 SSH 私钥的"只写不读"一致（spec 03 第 3 节）。
class HookTokensController < ApplicationController
  def create
    app = ManagedApp.find(params[:managed_app_id])
    require_permission!(:regenerate_hook_token, app)
    return if performed?

    token = app.regenerate_hook_token!

    redirect_to app, flash: { hook_token: token }
  end
end
