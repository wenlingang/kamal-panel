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
end
