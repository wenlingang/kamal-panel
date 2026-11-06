require "test_helper"

class NotificationChannelTest < ActiveSupport::TestCase
  def channel(**attributes)
    NotificationChannel.new(name: "ops", kind: "webhook", target: "https://hooks.example.com/abc", **attributes)
  end

  test "URL kinds must be https: the URL is the credential and the payload carries app details" do
    assert_predicate channel, :valid?

    %w[http://hooks.example.com/abc file:///etc/passwd not-a-url https://].each do |target|
      record = channel(target:)
      assert_not record.valid?, "#{target} should be refused"
      assert_predicate record.errors[:target], :any?
    end

    %w[feishu slack].each { |kind| assert_not channel(kind:, target: "http://x.example.com").valid? }
  end

  test "email takes comma-separated addresses, normalized, and refuses typos" do
    record = channel(kind: "email", target: " a@example.com,b@example.org ,, ")
    assert_predicate record, :valid?
    assert_equal "a@example.com, b@example.org", record.target
    assert_equal %w[a@example.com b@example.org], record.recipients

    assert_not channel(kind: "email", target: "a@example.com, nope").valid?
    assert_not channel(kind: "email", target: "a b@example.com").valid?
    assert_not channel(kind: "email", target: ([ "x@example.com" ] * 21).join(",")).valid?
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

  test "the hint shows the host, not the path that holds the token" do
    assert_equal "https://hooks.example.com/…", channel.target_hint
    assert_equal "…@example.com", channel(kind: "email", target: "a@example.com, b@example.com").tap(&:valid?).target_hint
  end

  test "a blank secret is stored as nil" do
    record = channel(secret: "  ")
    record.save!
    assert_nil record.secret
  end
end
