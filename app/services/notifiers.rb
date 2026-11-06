# Senders for alert notifications (spec 8), one per NotificationChannel kind. Each takes a
# Notifiers::Message and returns a Result instead of raising, so the delivery job and the "send
# test" button handle success and failure the same way.
module Notifiers
  Result = Data.define(:ok, :error) do
    def self.success = new(ok: true, error: nil)
    def self.failure(error) = new(ok: false, error: error.to_s)

    def ok? = ok
  end

  def self.for(channel)
    { "webhook" => Webhook, "feishu" => Feishu, "slack" => Slack, "email" => Email }
      .fetch(channel.kind).new(channel)
  end
end
