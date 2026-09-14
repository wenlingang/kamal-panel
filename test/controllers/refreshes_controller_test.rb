require "test_helper"

class RefreshesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @managed_app = ManagedApp.create!(name: "blog",
                                      config_yaml: file_fixture("simple_deploy.yml").read,
                                      destination: "production")
  end

  test "点刷新会把节奏顶到 burst 并入队一次采集" do
    sign_in_as users(:two)   # admin

    assert_enqueued_with(job: PollManagedAppJob) do
      post managed_app_refreshes_path(@managed_app)
    end

    assert_equal PollCadence::BURST, PollCadence.interval_for(@managed_app)
  end

  test "ops 也能刷新——采集是读动作，不改变线上任何状态" do
    sign_in_as users(:one)   # ops

    assert_enqueued_with(job: PollManagedAppJob) do
      post managed_app_refreshes_path(@managed_app)
    end

    assert_response :redirect
  end

  test "未登录不能刷新" do
    post managed_app_refreshes_path(@managed_app)

    assert_redirected_to new_session_path
  end

  test "三档角色都能手动刷新——它是读动作" do
    [ users(:one), users(:two), users(:three) ].each do |user|
      sign_in_as user

      assert_enqueued_with(job: PollManagedAppJob) do
        post managed_app_refreshes_path(@managed_app)
      end
    end
  end
end
