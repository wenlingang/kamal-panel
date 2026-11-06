# Settings → notifications: where alert notifications go (spec 8). Same shape as Git connections:
# admin only, the target and secret are write-only (a webhook URL is itself a credential), every
# change is audited.
class NotificationChannelsController < ApplicationController
  authorize :manage, on: NotificationChannel, only: %i[ index new create edit update destroy test_delivery ]

  before_action :set_channel, only: %i[ edit update destroy test_delivery ]

  def index
    @channels = NotificationChannel.includes(:alert_rules).order(:name)
  end

  def new
    @channel = NotificationChannel.new(kind: "webhook")
  end

  def create
    @channel = NotificationChannel.new(create_params)

    if @channel.save
      AuditLog.record_access!(user: Current.user, action_name: "notification_channel.create", detail: @channel.name)
      redirect_to notification_channels_path, notice: t("flash.notification_channel.added", name: @channel.name)
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  # Blank target / secret keep the current ones: the form never shows them, so an empty field means
  # "unchanged". Removing the secret is its own checkbox.
  def update
    attributes = update_params
    attributes = attributes.except(:target) if attributes[:target].blank?
    attributes = attributes.except(:secret) if attributes[:secret].blank?
    attributes[:secret] = nil if params.dig(:notification_channel, :clear_secret) == "1"
    attributes = attributes.except(:clear_secret)
    rotated = attributes.key?(:target) || attributes.key?(:secret)

    if @channel.update(attributes)
      AuditLog.record_access!(user: Current.user,
                              action_name: rotated ? "notification_channel.rotate" : "notification_channel.update",
                              detail: @channel.name)
      redirect_to notification_channels_path, notice: t("flash.notification_channel.updated", name: @channel.name)
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    name = @channel.name
    @channel.destroy!
    AuditLog.record_access!(user: Current.user, action_name: "notification_channel.delete", detail: name)
    redirect_to notification_channels_path, notice: t("flash.notification_channel.deleted", name: name)
  end

  # Sends right away so the admin sees the verdict; sends no alert data, so nothing to audit. Works
  # on a disabled channel too: checking it before switching it on is the point.
  def test_delivery
    result = @channel.deliver(Notifiers::Message.test(@channel))
    @channel.record_delivery!(result)

    if result.ok?
      redirect_to notification_channels_path, notice: t("flash.notification_channel.test_ok", name: @channel.name)
    else
      redirect_to notification_channels_path, alert: t("flash.notification_channel.test_failed", name: @channel.name,
                                                                                                 reason: result.error)
    end
  end

  private
    def set_channel = @channel = NotificationChannel.find(params[:id])

    def create_params = params.expect(notification_channel: [ :name, :kind, :target, :secret, :enabled ])

    # The kind stays put: the stored target means something only for its kind.
    def update_params = params.expect(notification_channel: [ :name, :target, :secret, :enabled, :clear_secret ])
end
