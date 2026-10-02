# 生成 / 重置上报 token。
class HookTokensController < ApplicationController
  def create
    app = ManagedApp.find(params[:managed_app_id])
    require_permission!(:regenerate_hook_token, app)
    return if performed?

    token = app.regenerate_hook_token!

    respond_to do |format|
      # 只把弹窗塞进插槽，页面不刷——明文 token 只在这一次出现，重新渲整页
      # 会让人刚看到脚本就被滚动位置和焦点的变化打断。
      format.turbo_stream { @managed_app, @token = app, token }
      # 没有 Turbo 时（禁用 JS）退回重定向，token 走 flash 由视图渲染。
      format.html { redirect_to app, flash: { hook_token: token } }
    end
  end
end
