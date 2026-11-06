require "test_helper"

class NotificationChannelsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @channel = NotificationChannel.create!(name: "ops", kind: "webhook", target: "https://hooks.example.com/original-token",
                                           secret: "original-secret")
  end

  test "denies non-admins every action" do
    [ users(:one), users(:three) ].each do |user|
      sign_in_as user

      get notification_channels_path
      assert_redirected_to root_path
      get new_notification_channel_path
      assert_redirected_to root_path
      get edit_notification_channel_path(@channel)
      assert_redirected_to root_path
      assert_no_difference -> { NotificationChannel.count } do
        post notification_channels_path, params: { notification_channel: { name: "x", kind: "webhook", target: "https://e.example.com" } }
      end
      patch notification_channel_path(@channel), params: { notification_channel: { target: "https://evil.example.com" } }
      delete notification_channel_path(@channel)
      post test_delivery_notification_channel_path(@channel)
      assert_redirected_to root_path
    end

    assert_equal "https://hooks.example.com/original-token", @channel.reload.target
    assert_equal 0, AuditLog.where("action_name LIKE 'notification_channel.%'").count
  end

  test "admin adds a channel; audited; target and secret never rendered back" do
    sign_in_as users(:two)

    post notification_channels_path, params: { notification_channel: {
      name: "飞书值班群", kind: "feishu", target: "https://open.feishu.cn/open-apis/bot/v2/hook/very-secret-hook",
      secret: "very-secret-sign", enabled: "1"
    } }
    assert_redirected_to notification_channels_path
    created = NotificationChannel.find_by!(name: "飞书值班群")
    assert AuditLog.exists?(action_name: "notification_channel.create", detail: "飞书值班群")

    get notification_channels_path
    assert_no_match "very-secret-hook", response.body
    assert_match "https://open.feishu.cn/…", response.body

    get edit_notification_channel_path(created)
    assert_no_match "very-secret-hook", response.body
    assert_no_match "very-secret-sign", response.body
  end

  test "an http URL is refused" do
    sign_in_as users(:two)

    post notification_channels_path, params: { notification_channel: { name: "plain", kind: "slack", target: "http://hooks.slack.com/x" } }

    assert_response :unprocessable_entity
    assert_not NotificationChannel.exists?(name: "plain")
  end

  test "blank fields keep the target and secret; replacing is audited as a rotation; the secret can be removed" do
    sign_in_as users(:two)

    patch notification_channel_path(@channel), params: { notification_channel: { name: "运维", target: "", secret: "" } }
    assert_equal [ "运维", "https://hooks.example.com/original-token", "original-secret" ],
                 [ @channel.reload.name, @channel.target, @channel.secret ]
    assert AuditLog.exists?(action_name: "notification_channel.update")

    patch notification_channel_path(@channel), params: { notification_channel: { target: "https://hooks.example.com/new", kind: "email" } }
    assert_equal [ "https://hooks.example.com/new", "webhook" ], [ @channel.reload.target, @channel.kind ]
    assert AuditLog.exists?(action_name: "notification_channel.rotate")

    patch notification_channel_path(@channel), params: { notification_channel: { clear_secret: "1" } }
    assert_nil @channel.reload.secret
  end

  test "send test reports the outcome and records it" do
    sign_in_as users(:two)

    stub_http("POST https://hooks.example.com/original-token" => [ 200 ]) do
      post test_delivery_notification_channel_path(@channel)
    end
    assert_redirected_to notification_channels_path
    assert_match "ops", flash[:notice]
    assert @channel.reload.last_delivered_at

    stub_http("POST https://hooks.example.com/original-token" => [ 403, "forbidden" ]) do
      post test_delivery_notification_channel_path(@channel)
    end
    assert_match "403", flash[:alert]
    assert_includes @channel.reload.last_error, "403"
  end

  test "deleting is audited" do
    sign_in_as users(:two)

    delete notification_channel_path(@channel)

    assert_not NotificationChannel.exists?(@channel.id)
    assert AuditLog.exists?(action_name: "notification_channel.delete", detail: "ops")
  end
end
