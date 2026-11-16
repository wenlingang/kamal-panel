# Alerts → silences: hold notifications for an app (or every app) for a while. Everyone signed in
# sees what is silenced (someone on call must know why nothing arrived); creating and ending a
# silence on one app needs act? on it, on every app needs admin.
class AlertSilencesController < ApplicationController
  def index
    @silences = AlertSilence.current_or_upcoming.includes(:managed_app, :user).order(:starts_at)
    @past = AlertSilence.where(ends_at: ..Time.current).includes(:managed_app, :user).order(ends_at: :desc).limit(20)
  end

  def new
    @silence = AlertSilence.new(managed_app_id: params[:managed_app_id], starts_at: Time.current)
    @apps = silenceable_apps
    @duration = 60
  end

  def create
    @apps = silenceable_apps
    attributes = params.expect(alert_silence: [ :managed_app_id, :reason, :starts_at ])
    @duration = params.dig(:alert_silence, :duration).presence&.to_i
    starts_at = Time.zone.parse(attributes[:starts_at].to_s) || Time.current
    starts_at = Time.current if starts_at < Time.current

    @silence = AlertSilence.new(managed_app_id: attributes[:managed_app_id].presence, reason: attributes[:reason].to_s.strip.presence,
                                starts_at:, ends_at: (starts_at + @duration.minutes if @duration),
                                user: Current.user, source: "manual")
    return redirect_to(alert_silences_path, alert: t("flash.no_permission")) unless may_manage?(@silence)

    if @silence.save
      AuditLog.record_access!(user: Current.user, action_name: "alert_silence.create", managed_app_id: @silence.managed_app_id,
                              detail: @silence.reason)
      redirect_to alert_silences_path, notice: t("flash.alert_silence.added")
    else
      render :new, status: :unprocessable_entity
    end
  end

  # Ends the silence now (or cancels one that hasn't started); the row stays as history.
  def destroy
    silence = AlertSilence.find(params[:id])
    return redirect_to(alert_silences_path, alert: t("flash.no_permission")) unless may_manage?(silence)

    silence.end!
    AuditLog.record_access!(user: Current.user, action_name: "alert_silence.end", managed_app_id: silence.managed_app_id,
                            detail: silence.reason)
    redirect_to alert_silences_path, notice: t("flash.alert_silence.ended")
  end

  private
    def may_manage?(silence)
      silence.global? ? Current.user.admin? : policy_for(silence.managed_app).act?
    end
    helper_method :may_manage?

    def silenceable_apps = ManagedApp.active.order(:name).select { |app| policy_for(app).act? }
end
