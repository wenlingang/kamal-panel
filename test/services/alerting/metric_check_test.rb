require "test_helper"

class Alerting::MetricCheckTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Rails.cache.clear
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production")
    @now = Time.current.change(sec: 0)
  end

  def rule(condition, threshold: 80, for_minutes: 0)
    AlertRule.create!(name: condition, condition:, metric_threshold: threshold, for_minutes:)
  end

  def container(at, cpu: 10, mem_percent: 10, name: "blog-web-production-a", kind: "app")
    ContainerMetric.create!(managed_app: @app, host: "127.0.0.1", container_name: name, source: kind == "proxy" ? "kamal-proxy" : "web",
                            kind:, cpu_percent: cpu, mem_percent:, sampled_at: at)
  end

  def host(at, mem_used: 0.5, disk_used: 0.5)
    HostMetric.create!(managed_app: @app, host: "127.0.0.1", mem_total_bytes: 100, mem_available_bytes: (100 * (1 - mem_used)).round,
                       disk_total_bytes: 100, disk_used_bytes: (100 * disk_used).round, sampled_at: at)
  end

  def check(rule, now: @now) = Alerting::MetricCheck.call(rule, @app, now:)

  test "no recent sample is no verdict, never a clear" do
    container(@now - 10.minutes, cpu: 99, mem_percent: 99)
    host(@now - 10.minutes, mem_used: 0.99, disk_used: 0.99)

    %w[cpu_high memory_high host_memory_high host_disk_high].each do |condition|
      assert_nil check(rule(condition)), condition
    end
  end
end
