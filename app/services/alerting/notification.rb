module Alerting
  # Fans one transition out to the rule's enabled channels, one job each, so a slow or broken
  # channel delays nobody else and is retried on its own.
  module Notification
    KINDS = %w[firing reminder resolved].freeze

    module_function

    def enqueue(event, kind)
      raise ArgumentError, "unknown notification kind: #{kind}" unless KINDS.include?(kind)

      event.alert_rule.notification_channels.enabled.find_each do |channel|
        DeliverAlertNotificationJob.perform_later(event, channel, kind)
      end
    end
  end
end
