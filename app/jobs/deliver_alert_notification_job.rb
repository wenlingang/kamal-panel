# Sends one notification to one channel. A failure is recorded on the channel (shown on the
# settings page) and retried a couple of times; after that it is given up, since a notification
# hours late is worse than the recorded error that explains its absence.
class DeliverAlertNotificationJob < ApplicationJob
  class DeliveryFailed < StandardError; end

  queue_as :default

  retry_on DeliveryFailed, wait: 30.seconds, attempts: 3 do |job, error|
    Rails.logger.warn("[alerts] 通知投递放弃：#{job.arguments.second&.name}: #{error.message}")
  end
  discard_on ActiveJob::DeserializationError

  def perform(event, channel, kind)
    return unless channel.enabled?

    result = channel.deliver(Notifiers::Message.for_event(event, kind))
    channel.record_delivery!(result)
    raise DeliveryFailed, result.error unless result.ok?
  end
end
