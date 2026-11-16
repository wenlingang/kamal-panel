# Monday morning: WeeklySummary to every enabled channel that opted in (weekly_summary).
class WeeklySummaryJob < ApplicationJob
  queue_as :alerts

  def perform
    channels = NotificationChannel.enabled.where(weekly_summary: true).to_a
    return if channels.empty? || !ManagedApp.active.exists?

    message = WeeklySummary.new.message
    channels.each do |channel|
      channel.record_delivery!(channel.deliver(message))
    rescue StandardError => e
      Rails.logger.error("[weekly_summary] #{channel.name}: #{e.class}: #{e.message}")
    end
  end
end
