class ManagedAppsController < ApplicationController
  authorize :create_app, on: ManagedApp, only: %i[ new create ]

  before_action :set_managed_app, only: %i[ edit update ]
  before_action :set_managed_app_for_lifecycle, only: %i[ deactivate reactivate ]

  def index
    @managed_apps = ManagedApp.active.order(:name)
    @deactivated_apps = ManagedApp.where.not(deactivated_at: nil).order(:name)
  end

  def show
    @managed_app = ManagedApp.find(params[:id])

    PollCadence.mark_viewed!(@managed_app)
  end

  def new
    @managed_app = ManagedApp.new
  end

  def create
    @managed_app = ManagedApp.new(create_params)

    if @managed_app.save
      redirect_to @managed_app, notice: t("flash.app.onboarded", name: @managed_app.service)
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    changed = update_params.keys.select { |key| @managed_app.send(key) != update_params[key] }

    if @managed_app.update(update_params)
      clear_poll_error_if_config_changed(changed)
      # 权限变更必须留痕。detail 只记字段名——记值等于把密文写进审计表。
      AuditLog.record_access!(user: Current.user, action_name: "app.update",
                              managed_app: @managed_app,
                              detail_key: "app.update_fields",
                              detail_args: { "fields" => changed.map(&:to_s) })
      redirect_to @managed_app, notice: t("flash.app.updated", name: @managed_app.name)
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def deactivate
    @managed_app.deactivate!
    AuditLog.record_access!(user: Current.user, action_name: "app.deactivate",
                            managed_app: @managed_app, detail: @managed_app.name)
    redirect_to @managed_app, notice: t("flash.app.deactivated", name: @managed_app.name)
  end

  def reactivate
    @managed_app.reactivate!
    AuditLog.record_access!(user: Current.user, action_name: "app.reactivate",
                            managed_app: @managed_app, detail: @managed_app.name)
    redirect_to edit_managed_app_path(@managed_app),
                notice: t("flash.app.reactivated", name: @managed_app.name)
  end

  private
    def set_managed_app
      @managed_app = ManagedApp.find(params[:id])
      require_permission!(:act, @managed_app)
    end

    def set_managed_app_for_lifecycle
      @managed_app = ManagedApp.find(params[:id])
      require_permission!(:deactivate, @managed_app)
    end

    def create_params
      params.expect(managed_app: [ :name, :config_yaml, :destination, :destination_config_yaml,
                                   :kamal_secrets, :kamal_hooks,
                                   :ssh_credential_id, :registry_credential_id ])
    end

    def update_params
      permitted = [ :name, :config_yaml, :destination_config_yaml, :kamal_secrets, :kamal_hooks ]
      permitted += [ :ssh_credential_id, :registry_credential_id ] if assign_credentials?

      params.expect(managed_app: permitted)
    end

    def assign_credentials?
      policy_for(@managed_app).assign_credentials?
    end
    helper_method :assign_credentials?

    # 指控新配置，直到下一轮采集。新配置若也坏，下一轮会重新记上。
    def clear_poll_error_if_config_changed(changed)
      return if (changed & %w[config_yaml destination_config_yaml]).empty?
      return if @managed_app.last_poll_error.nil?

      @managed_app.update_columns(last_poll_error: nil, last_poll_error_at: nil,
                                  first_poll_error_at: nil)
    end
end
