require "test_helper"

class NotificationChannelTest < ActiveSupport::TestCase
  def channel(**attributes)
    NotificationChannel.new(name: "ops", kind: "webhook", target: "https://hooks.example.com/abc", **attributes)
  end

  test "target and secret are encrypted and never in a serialized hash" do
    record = channel(secret: "s3cret")
    record.save!

    raw = NotificationChannel.connection.select_one("SELECT target, secret FROM notification_channels WHERE id = #{record.id}")
    assert_no_match "hooks.example.com/abc", raw["target"]
    assert_no_match "s3cret", raw["secret"]
    assert_not_includes record.serializable_hash.keys, "target"
    assert_not_includes record.serializable_hash.keys, "secret"
  end
end
