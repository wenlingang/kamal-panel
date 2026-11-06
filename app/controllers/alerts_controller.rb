# The alerts page (spec 8): what is firing now, then the history; the rules and channels tabs.
# Readable by everyone signed in — an alert is only useful if the person on call can see it.
class AlertsController < ApplicationController
  def index
    @firing = AlertEvent.firing.includes(:alert_rule, :managed_app).order(fired_at: :desc)
    @filter = AlertEventFilter.new(**params.permit(:app_id, :state, :before).to_h.symbolize_keys)
    @page = @filter.page
    @apps = ManagedApp.where(id: AlertEvent.select(:managed_app_id)).order(:name)
  end

  # The read-only list (masked targets) for everyone; managing them is under settings.
  def channels
    @channels = NotificationChannel.includes(:alert_rules).order(:name)
  end
end
