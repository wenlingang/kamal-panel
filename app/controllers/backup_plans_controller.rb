# An app's accessory backups (the list is the app's backups tab): set one up, change it, remove it,
# or back it up right now. Anyone who may act on the app may manage its backups.
class BackupPlansController < ApplicationController
  before_action :set_managed_app
  before_action :set_plan, only: %i[ edit update destroy run ]

  def new
    candidate = BackupPlan.candidates(@managed_app).find { |c| c[:name] == params[:accessory] } ||
                BackupPlan.candidates(@managed_app).first
    @plan = @managed_app.backup_plans.new(accessory: candidate&.dig(:name), engine: candidate&.dig(:engine),
                                          backup_destination: BackupDestination.order(:name).first)
  end

  def create
    @plan = @managed_app.backup_plans.new(plan_params)

    if @plan.save
      AuditLog.record_access!(user: Current.user, action_name: "backup_plan.create", managed_app: @managed_app, detail: @plan.accessory)
      redirect_to backups_tab, notice: t("flash.backup_plan.added", accessory: @plan.accessory)
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    # The accessory is what the plan is about; changing it is a new plan.
    if @plan.update(plan_params.except(:accessory))
      AuditLog.record_access!(user: Current.user, action_name: "backup_plan.update", managed_app: @managed_app, detail: @plan.accessory)
      redirect_to backups_tab, notice: t("flash.backup_plan.updated", accessory: @plan.accessory)
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Removes the plan and its history here; the dumps already in the bucket stay there.
  def destroy
    @plan.destroy!
    AuditLog.record_access!(user: Current.user, action_name: "backup_plan.delete", managed_app: @managed_app, detail: @plan.accessory)
    redirect_to backups_tab, notice: t("flash.backup_plan.deleted", accessory: @plan.accessory)
  end

  def run
    RunBackupJob.perform_later(@plan, Current.user)
    AuditLog.record_access!(user: Current.user, action_name: "backup.run", managed_app: @managed_app, detail: @plan.accessory)
    redirect_to backups_tab, notice: t("flash.backup_plan.started", accessory: @plan.accessory)
  end

  private
    def set_managed_app
      @managed_app = ManagedApp.find(params[:managed_app_id])
      require_permission!(:act, @managed_app)
    end

    def set_plan = @plan = @managed_app.backup_plans.find(params[:id])

    def plan_params
      params.expect(backup_plan: [ :accessory, :engine, :database, :backup_destination_id, :every_hours, :keep, :enabled ])
    end

    def backups_tab = managed_app_path(@managed_app, tab: "backups")
end
