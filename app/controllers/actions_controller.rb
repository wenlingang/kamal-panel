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
    # 审计记录必须限定在这个应用下：否则 /apps/<任意应用>/actions/<任意 id>
    # 会把别的应用的执行输出挂在这个应用的面包屑下渲染出来。
    @audit_log = AuditLog.where(managed_app: @managed_app).find(params[:id])

    # 执行页会把动作的完整输出渲染出来。能不能看这一页，必须和当初能不能
    # 发起这个动作走同一个判断——否则 ops 跑过一次 logs 之后，任何登录用户
    # 都能把这个应用的服务日志读完（整分支评审 I1）。
    action_class = Actions::Base.find(@audit_log.action_name)
    unless ManagedAppPolicy.new(Current.user, @managed_app).run?(action_class)
      redirect_to @managed_app, alert: t("flash.no_permission")
    end
  rescue Actions::Base::UnknownAction
    # 这一页只渲染动作类审计。app.add_member / app.remove_member 这类权限变更
    # 的审计行也带着 managed_app_id，作用域那一关拦不住它们，走到这里 find 会
    # 抛 UnknownAction——它们属于审计列表，不属于执行页。落到"拒绝"这一侧，
    # 而不是让一条手输的 URL 打出 500（create 里用的是同一个 rescue 模式）。
    redirect_to @managed_app, alert: t("flash.no_permission")
  end
end
