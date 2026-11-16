# Settings → backup storage: the S3-compatible buckets accessory backups go to. Same shape as
# notification channels: admin only, the secret key is write-only, every change is audited.
class BackupDestinationsController < ApplicationController
  authorize :manage, on: BackupDestination, only: %i[ index new create edit update destroy check ]

  before_action :set_destination, only: %i[ edit update destroy check ]

  def index
    @destinations = BackupDestination.includes(backup_plans: :managed_app).order(:name)
  end

  def new
    @destination = BackupDestination.new
  end

  def create
    @destination = BackupDestination.new(destination_params)

    if @destination.save
      AuditLog.record_access!(user: Current.user, action_name: "backup_destination.create", detail: @destination.name)
      redirect_after_check(t("flash.backup_destination.added", name: @destination.name))
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  # A blank secret keeps the current one: the form never shows it.
  def update
    attributes = destination_params
    attributes = attributes.except(:secret_access_key) if attributes[:secret_access_key].blank?
    rotated = attributes.key?(:secret_access_key) || attributes[:access_key_id].to_s.strip != @destination.access_key_id

    if @destination.update(attributes)
      AuditLog.record_access!(user: Current.user,
                              action_name: rotated ? "backup_destination.rotate" : "backup_destination.update",
                              detail: @destination.name)
      redirect_after_check(t("flash.backup_destination.updated", name: @destination.name))
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    name = @destination.name
    if @destination.destroy
      AuditLog.record_access!(user: Current.user, action_name: "backup_destination.delete", detail: name)
      redirect_to backup_destinations_path, notice: t("flash.backup_destination.deleted", name:)
    else
      redirect_to backup_destinations_path, alert: t("flash.backup_destination.in_use", name:)
    end
  end

  def check
    redirect_after_check(nil)
  end

  private
    def set_destination = @destination = BackupDestination.find(params[:id])

    def destination_params
      params.expect(backup_destination: [ :name, :endpoint, :region, :bucket, :prefix, :path_style,
                                          :access_key_id, :secret_access_key ])
    end

    # Saving checks right away: a typo in the bucket should show up now, not at 3 a.m.
    def redirect_after_check(saved_notice)
      error = @destination.check!
      if error
        redirect_to backup_destinations_path, alert: [ saved_notice, t("flash.backup_destination.check_failed", name: @destination.name, reason: error) ].compact.join(" ")
      else
        redirect_to backup_destinations_path, notice: [ saved_notice, t("flash.backup_destination.check_ok", name: @destination.name) ].compact.join(" ")
      end
    end
end
