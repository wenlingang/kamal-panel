class ActionsController < ApplicationController
  def create
    app = ManagedApp.find(params[:managed_app_id])
    action_class = Actions::Base.find(params[:name])

    unless ManagedAppPolicy.new(Current.user, app).run?(action_class)
      return redirect_to actions_tab(app), alert: t("flash.no_permission")
    end

    if action_class.confirm_by_name? && params[:confirm_name] != app.name
      return redirect_to actions_tab(app), alert: t("flash.confirm_name_failed")
    end

    # The target (accessory name / host) is checked against the app's parsed config before
    # anything is audited: an audit row for an action aimed at something deploy.yml doesn't declare
    # would record an operation that could never have run.
    action = action_class.new(app, target_version: params[:version].presence, target: params[:target].presence)
    action.validate!

    log = AuditLog.start!(user: Current.user, managed_app: app,
                          action_name: params[:name], target_version: params[:version],
                          target: action.target, hosts: action.affected_hosts)
    RunActionJob.perform_later(log.id)

    redirect_to managed_app_action_path(app, log)
  rescue Actions::Base::UnknownAction
    redirect_to actions_tab(app), alert: t("flash.unknown_action")
  rescue Actions::Base::InvalidTarget
    redirect_to actions_tab(app), alert: t("flash.invalid_target")
  rescue Actions::Base::InvalidVersion
    redirect_to actions_tab(app), alert: t("flash.invalid_version")
  rescue Kamal::ConfigParser::ParseError
    redirect_to actions_tab(app), alert: t("flash.config_unparseable")
  end

  def show
    @managed_app = ManagedApp.find(params[:managed_app_id])
    # would render another app's execution output under this app's breadcrumb.
    @audit_log = AuditLog.where(managed_app: @managed_app).find(params[:id])

    action_class = Actions::Base.find(@audit_log.action_name)
    unless ManagedAppPolicy.new(Current.user, @managed_app).run?(action_class)
      redirect_to @managed_app, alert: t("flash.no_permission")
    end
  rescue Actions::Base::UnknownAction
    redirect_to @managed_app, alert: t("flash.no_permission")
  end

  private
    # A refused action sends people back to the tab they submitted from, where the form and the
    # flash explaining the refusal sit together.
    def actions_tab(app) = managed_app_path(app, tab: "actions")
end
