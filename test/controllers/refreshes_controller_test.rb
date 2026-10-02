require "test_helper"

class RefreshesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @managed_app = ManagedApp.create!(name: "blog",
                                      config_yaml: file_fixture("simple_deploy.yml").read,
                                      destination: "production")
  end

  test "clicking refresh bumps the cadence to burst and enqueues one collection" do
    sign_in_as users(:two)   # admin

    assert_enqueued_with(job: PollManagedAppJob) do
      post managed_app_refreshes_path(@managed_app)
    end

    assert_equal PollCadence::BURST, PollCadence.interval_for(@managed_app)
  end

  test "lets ops refresh too, since collection is a read action that changes no production state" do
    sign_in_as users(:one)   # ops

    assert_enqueued_with(job: PollManagedAppJob) do
      post managed_app_refreshes_path(@managed_app)
    end

    assert_response :redirect
  end

  test "does not allow refreshing when signed out" do
    post managed_app_refreshes_path(@managed_app)

    assert_redirected_to new_session_path
  end

  test "lets all three roles refresh manually since it is a read action" do
    [ users(:one), users(:two), users(:three) ].each do |user|
      sign_in_as user

      assert_enqueued_with(job: PollManagedAppJob) do
        post managed_app_refreshes_path(@managed_app)
      end
    end
  end
end
