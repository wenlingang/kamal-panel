require "test_helper"

class CollectMetricsJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Rails.cache.clear
    @key = Credential.create!(kind: "ssh_key", name: "k", value: File.read(Rails.root.join("test/fake_host/id_ed25519")))
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production",
                              ssh_credential: @key)
  end

  test "is scheduled every minute in every environment that runs recurring tasks" do
    config = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    %w[production development].each do |env|
      task = config.fetch(env).fetch("collect_all_metrics")
      assert_equal "CollectAllMetricsJob", task["class"]
      assert_equal "every minute", task["schedule"]
    end
  end

  test "fans out to active apps with an SSH key and a config that parses" do
    ManagedApp.create!(name: "nokey", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production")
    broken = ManagedApp.create!(name: "broken", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production",
                                ssh_credential: @key)
    broken.update_columns(last_poll_error: "boom")
    off = ManagedApp.create!(name: "off", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production",
                             ssh_credential: @key)
    off.update_columns(deactivated_at: Time.current)

    assert_enqueued_with(job: CollectMetricsJob, args: [ @app ]) do
      assert_enqueued_jobs 1, only: CollectMetricsJob do
        CollectAllMetricsJob.perform_now
      end
    end
  end

  test "one round per app at a time; overlapping ones are dropped" do
    assert_equal 1, CollectMetricsJob.concurrency_limit
    assert_equal :discard, CollectMetricsJob.concurrency_on_conflict
  end

  test "skips an app that lost its key or broke since it was enqueued" do
    assert CollectMetricsJob.collectable?(@app)

    @app.update_columns(last_poll_error: "boom")
    assert_not CollectMetricsJob.collectable?(@app)
    assert_nil CollectMetricsJob.perform_now(@app), "no SSH attempted"

    @app.update_columns(last_poll_error: nil, ssh_credential_id: nil)
    assert_not CollectMetricsJob.collectable?(@app.reload)
  end
end
