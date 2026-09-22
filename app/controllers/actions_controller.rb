class ActionsController < ApplicationController
  def create
    app = ManagedApp.find(params[:managed_app_id])
    action_class = Actions::Base.find(params[:name])

    unless ManagedAppPolicy.new(Current.user, app).run?(action_class)
      return redirect_to app, alert: t("flash.no_permission")
    end

    if action_class.confirm_by_name? && params[:confirm_name] != app.name
      return redirect_to app, alert: t("flash.confirm_name_failed")
    end

    log = AuditLog.start!(user: Current.user, managed_app: app,
                          action_name: params[:name], target_version: params[:version],
                          hosts: action_class.new(app).affected_hosts)
    RunActionJob.perform_later(log.id)

    redirect_to managed_app_action_path(app, log)
  rescue Actions::Base::UnknownAction
    redirect_to app, alert: t("flash.unknown_action")
  end

  def show
    @managed_app = ManagedApp.find(params[:managed_app_id])
    # 会把别的应用的执行输出挂在这个应用的面包屑下渲染出来。
    @audit_log = AuditLog.where(managed_app: @managed_app).find(params[:id])

    action_class = Actions::Base.find(@audit_log.action_name)
    unless ManagedAppPolicy.new(Current.user, @managed_app).run?(action_class)
      redirect_to @managed_app, alert: t("flash.no_permission")
    end
  rescue Actions::Base::UnknownAction
    redirect_to @managed_app, alert: t("flash.no_permission")
  end
end
