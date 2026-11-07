require "test_helper"

class CollectMetricsJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Rails.cache.clear
    @key = Credential.create!(kind: "ssh_key", name: "k", value: File.read(Rails.root.join("test/fake_host/id_ed25519")))
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production",
                              ssh_credential: @key)
  end

  test "spreads the round over the window instead of enqueuing it all at once" do
    others = 2.times.map do |i|
      ManagedApp.create!(name: "app#{i}", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production",
                         ssh_credential: @key)
    end

    freeze_time do
      CollectAllMetricsJob.perform_now

      offsets = enqueued_jobs.select { |job| job["job_class"] == "CollectMetricsJob" }
                             .map { |job| (Time.parse(job["scheduled_at"]) - Time.current).round }
      assert_equal [ 0, 15, 30 ], offsets.sort
      assert_equal 1 + others.size, offsets.size
      assert offsets.all? { |offset| offset < CollectAllMetricsJob::SPREAD }
    end
  end
end
