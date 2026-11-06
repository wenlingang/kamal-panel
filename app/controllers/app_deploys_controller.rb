# Deploying one app (spec 6): the version list (a frame on the deploy tab), the confirm page and
# the POST. The POST goes through the same closed action set as everything else (Actions::Deploy,
# AuditLog.start!, RunActionJob, which checks the deploy lock before running).
class AppDeploysController < ApplicationController
  before_action :set_managed_app

  # The frame body of the deploy tab. Slow by nature (Git platform + registry), which is why it is
  # a frame and not part of the tab.
  def versions
    @live_versions = ManagedAppStatus.new(@managed_app).versions
    @rows = load_rows if @managed_app.git_configured?

    render layout: false
  end

  # The confirm page itself is the confirmation: no typed name, unlike rollback, because here the
  # person has just picked the version from a list and sees what changes before pressing deploy.
  def new
    @version = params[:version].to_s.strip
    Actions::Deploy.new(@managed_app, target_version: @version).validate!
    # Parse now, inside the rescue below: the page lists roles and hosts, and a parse failure
    # while rendering would surface as a 500 instead of a message.
    @managed_app.parsed_config

    @preview = DeployPreview.new(@managed_app, @version)
  rescue Actions::Base::InvalidVersion
    redirect_to deploy_tab, alert: t("flash.invalid_version")
  rescue Kamal::ConfigParser::ParseError
    redirect_to deploy_tab, alert: t("flash.config_unparseable")
  end

  def create
    action = Actions::Deploy.new(@managed_app, target_version: params[:version].to_s.strip)
    action.validate!

    log = AuditLog.start!(user: Current.user, managed_app: @managed_app, action_name: "deploy",
                          target_version: action.target_version, hosts: action.affected_hosts)
    RunActionJob.perform_later(log.id)

    redirect_to managed_app_action_path(@managed_app, log)
  rescue Actions::Base::InvalidVersion
    redirect_to deploy_tab, alert: t("flash.invalid_version")
  rescue Kamal::ConfigParser::ParseError
    redirect_to deploy_tab, alert: t("flash.config_unparseable")
  end

  private
    # Deploying is act? (spec 9), same as restart. The version list and confirm page use the same
    # check: they spend the Git token's quota and lead nowhere for anyone who can't deploy.
    def set_managed_app
      @managed_app = ManagedApp.find(params[:managed_app_id])
      require_permission!(:act, @managed_app)
    end

    def deploy_tab = managed_app_path(@managed_app, tab: "deploy")

    # A Git platform outage degrades the list to "type a version", it doesn't break the tab.
    def load_rows
      DeployCandidates.new(@managed_app, live_versions: @live_versions).rows
    rescue GitProviders::Error => e
      @git_error = e.message
      nil
    end
end
