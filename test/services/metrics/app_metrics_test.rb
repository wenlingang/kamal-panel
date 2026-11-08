require "test_helper"

class Metrics::AppMetricsTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog", destination: "production", config_yaml: <<~YAML)
      service: blog
      image: example/blog
      servers:
        web:
          - 10.0.0.1
          - 10.0.0.2
          - 10.0.0.3
      registry:
        server: registry.example.com
        username: someone
        password:
          - KAMAL_REGISTRY_PASSWORD
      builder:
        arch: amd64
    YAML
    @now = Time.zone.parse("2026-11-08 10:00:30")
  end

  def metrics = Metrics::AppMetrics.new(@app, range: Metrics::TimeRange.new(nil), hosts: %w[10.0.0.1 10.0.0.2 10.0.0.3])

  test "says which hosts the collection settings turned down, so empty charts aren't read as failures" do
    with_collection_settings(hosts: { "10.0.0.2" => { metrics: { enabled: false } },
                                      "10.0.0.3" => { metrics: { containers: false } } }) do
      assert_equal %w[10.0.0.2], metrics.hosts_not_collected
      assert_equal %w[10.0.0.3], metrics.hosts_without_containers
      refute metrics.nothing_collected?
    end

    with_collection_settings(metrics: { enabled: false }) { assert metrics.nothing_collected? }
  end

  test "a host sampled every N minutes keeps its last sample current for twice that" do
    HostMetric.create!(managed_app: @app, host: "10.0.0.1", sampled_at: 8.minutes.ago.change(sec: 0), load1: 0.5)

    assert_nil metrics.latest_hosts["10.0.0.1"], "every minute: an 8-minute-old sample is stale"

    with_collection_settings(hosts: { "10.0.0.1" => { metrics: { every: 5 } } }) do
      assert_equal 10.minutes, metrics.freshness_for("10.0.0.1")
      assert_not_nil metrics.latest_hosts["10.0.0.1"]
    end
  end
end
