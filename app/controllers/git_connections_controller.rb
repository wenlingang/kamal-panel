# Settings → Git: the API tokens the panel reads commits and CI status with (spec 6). Same shape as
# credentials: admin only, the token is write-only, every change is audited, and a connection apps
# still use can't be deleted.
class GitConnectionsController < ApplicationController
  authorize :manage, on: GitConnection, only: %i[ index new create edit update destroy check ]

  before_action :set_connection, only: %i[ edit update destroy check ]

  def index
    @connections = GitConnection.includes(:managed_apps).order(:name)
  end

  def new
    @connection = GitConnection.new(provider: "github")
  end

  def create
    @connection = GitConnection.new(create_params)

    if @connection.save
      AuditLog.record_access!(user: Current.user, action_name: "git_connection.create",
                              detail: @connection.name)
      redirect_to git_connections_path, notice: t("flash.git_connection.added", name: @connection.name)
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  # A blank token keeps the current one: the form never shows it, so an empty field means
  # "unchanged", not "remove" — except with a new API address, which needs the token typed again
  # (GitConnection#token_reentered_for_new_api_url).
  def update
    attributes = update_params
    attributes = attributes.except(:token) if attributes[:token].blank?
    rotated = attributes.key?(:token)
    @connection.token_reentered = rotated

    if @connection.update(attributes)
      AuditLog.record_access!(user: Current.user,
                              action_name: rotated ? "git_connection.rotate" : "git_connection.update",
                              detail: @connection.name)
      redirect_to git_connections_path, notice: t("flash.git_connection.updated", name: @connection.name)
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    name = @connection.name

    if @connection.destroy
      AuditLog.record_access!(user: Current.user, action_name: "git_connection.delete", detail: name)
      redirect_to git_connections_path, notice: t("flash.git_connection.deleted", name: name)
    else
      apps = @connection.managed_apps.map(&:name).join(t("common.list_separator"))
      redirect_to git_connections_path, alert: t("flash.git_connection.blocked", name: name, apps: apps)
    end
  end

  # Read-only (GET /user on the provider), so nothing to audit.
  def check
    login = @connection.check!
    redirect_to git_connections_path, notice: t("flash.git_connection.check_ok", name: @connection.name,
                                                                                 login: login.to_s)
  rescue GitProviders::Error => e
    redirect_to git_connections_path, alert: t("flash.git_connection.check_failed", name: @connection.name,
                                                                                    reason: e.message)
  end

  private
    def set_connection = @connection = GitConnection.find(params[:id])

    def create_params = params.expect(git_connection: [ :name, :provider, :api_url, :web_url, :ca_certificate, :token ])

    # The provider stays put: switching it would make every app's repository path mean something else.
    def update_params = params.expect(git_connection: [ :name, :api_url, :web_url, :ca_certificate, :token ])
end
