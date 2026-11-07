require "test_helper"

class PollAllManagedAppsJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Rails.cache.clear
    @app = ManagedApp.create!(
      name: "blog-#{SecureRandom.hex(4)}", config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )
  end

  test "enqueues only once for two back-to-back schedules because slot claiming is atomic" do
    assert_enqueued_jobs 1, only: PollManagedAppJob do
      PollAllManagedAppsJob.perform_now
      PollAllManagedAppsJob.perform_now
    end
  end

  # The app in setup is alive, so here we [cannot] assert "nothing was enqueued" -- that would test
  # something else. What to assert: the disabled one doesn't appear in the enqueued arguments.
  test "no longer polls deactivated apps" do
    gone = ManagedApp.create!(name: "gone-#{SecureRandom.hex(4)}",
                              config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    gone.deactivate!

    PollAllManagedAppsJob.perform_now

    polled = enqueued_jobs.select { |job| job["job_class"] == "PollManagedAppJob" }
                          .flat_map { |job| job["arguments"] }
                          .filter_map { |arg| arg.is_a?(Hash) ? arg["_aj_globalid"] : nil }

    assert polled.any? { |gid| gid.include?("ManagedApp/#{@app.id}") }, "An active app should be enqueued as usual"
    refute polled.any? { |gid| gid.include?("ManagedApp/#{gone.id}") }, "A deactivated app must not be enqueued"
  end
end
