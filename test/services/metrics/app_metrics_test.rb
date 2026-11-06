require "test_helper"

class Metrics::AppMetricsTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production")
    @now = Time.zone.parse("2026-11-05 12:00:00")
  end

  def container(at, cpu:, mem: 100, source: "web", kind: "app", name: "blog-web-production-aaa", host: "127.0.0.1", limit: nil)
    ContainerMetric.create!(managed_app: @app, host:, container_name: name, source:, kind:, cpu_percent: cpu,
                            mem_bytes: mem, mem_limit_bytes: limit, mem_percent: 10, sampled_at: at)
  end

  def host_sample(at, load1: 1.0, used: 0.5, disk: 0.25)
    HostMetric.create!(managed_app: @app, host: "127.0.0.1", load1:, cpus: 2, mem_total_bytes: 1000, mem_available_bytes: (1000 * (1 - used)).round,
                       disk_total_bytes: 100, disk_used_bytes: (100 * disk).round, sampled_at: at)
  end

  test "ranges pick a bucket so a series stays a few hundred points; unknown keys fall back to 1h" do
    points = Metrics::TimeRange::OPTIONS.map { |_, (span, bucket)| span / bucket }
    assert points.all? { |count| count.between?(60, 340) }, points.inspect
    assert_equal "1h", Metrics::TimeRange.new("1y").key
    assert_equal "7d", Metrics::TimeRange.new("7d").key
  end

  test "container samples are averaged per series and bucket" do
    container(@now - 50.minutes, cpu: 10, mem: 100)
    container(@now - 49.minutes, cpu: 20, mem: 300)  # same 30-min bucket on the 7d range
    container(@now - 10.minutes, cpu: 40, mem: 500)
    container(@now - 10.minutes, cpu: 1, source: "kamal-proxy", kind: "proxy", name: "kamal-proxy")

    week = Metrics::AppMetrics.new(@app, range: Metrics::TimeRange.new("7d", now: @now))
    web = week.container_cpu_series.find { |series| series.key == "web@127.0.0.1" }
    assert_equal [ 15.0, 40.0 ], web.values
    assert_equal "web @ 127.0.0.1", web.label
    assert_equal [ 200.0, 500.0 ], week.container_mem_series.first.values
    assert_equal [ "web@127.0.0.1", "kamal-proxy@127.0.0.1" ], week.container_cpu_series.map(&:key), "app before proxy"

    hour = Metrics::AppMetrics.new(@app, range: Metrics::TimeRange.new("1h", now: @now))
    assert_equal [ 10.0, 20.0, 40.0 ], hour.container_cpu_series.first.values, "a minute per bucket on 1h"
    assert_equal 40.0, hour.container_cpu_series.first.latest
  end

  test "samples outside the range are left out, and memory limits are reported per series" do
    container(@now - 2.hours, cpu: 99)
    container(@now - 5.minutes, cpu: 5, limit: 512)

    metrics = Metrics::AppMetrics.new(@app, range: Metrics::TimeRange.new("1h", now: @now))
    assert_equal [ 5.0 ], metrics.container_cpu_series.first.values
    assert_equal({ "web@127.0.0.1" => 512 }, metrics.container_mem_limits)
  end

  test "host series per configured host: load, cores, memory and disk used %" do
    host_sample(@now - 3.minutes, load1: 1.0, used: 0.5, disk: 0.25)
    host_sample(@now - 2.minutes, load1: 3.0, used: 0.7, disk: 0.25)

    metrics = Metrics::AppMetrics.new(@app, range: Metrics::TimeRange.new("1h", now: @now))
    series = metrics.host_series.fetch("127.0.0.1")
    assert_equal [ 1.0, 3.0 ], series[:load1].values
    assert_equal 2.0, series[:cpus].latest
    assert_equal [ 50.0, 70.0 ], series[:mem].values.map(&:round)
    assert_equal [ 25.0, 25.0 ], series[:disk].values.map(&:round)
    assert_predicate metrics, :any_data?
  end

  test "latest values: newest sample per container and host, nothing older than 5 minutes" do
    container(@now - 3.minutes, cpu: 10)
    container(@now - 1.minute, cpu: 30)
    container(@now - 20.minutes, cpu: 1, name: "blog-web-production-old")
    host_sample(@now - 1.minute, load1: 2.5)

    metrics = Metrics::AppMetrics.new(@app, range: Metrics::TimeRange.new("1h", now: @now))
    assert_equal [ 30.0 ], metrics.latest_containers.map(&:cpu_percent)
    assert_equal 2.5, metrics.latest_hosts.fetch("127.0.0.1").load1
  end

  test "no samples: no data" do
    assert_not Metrics::AppMetrics.new(@app, range: Metrics::TimeRange.new("1h", now: @now)).any_data?
  end

  test "card summary: the app's containers summed at their latest minute, the proxy left out, one query" do
    container(@now - 2.minutes, cpu: 10, mem: 100)
    container(@now - 1.minute, cpu: 12, mem: 100)
    container(@now - 1.minute, cpu: 3, mem: 50, source: "worker", name: "blog-worker-production-aaa")
    container(@now - 1.minute, cpu: 50, mem: 999, source: "kamal-proxy", kind: "proxy", name: "kamal-proxy")
    stale = ManagedApp.create!(name: "old", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production")
    ContainerMetric.create!(managed_app: stale, host: "x", container_name: "c", source: "web", kind: "app", cpu_percent: 1, sampled_at: @now - 30.minutes)

    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
    summaries = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      Metrics::CardSummary.for([ @app, stale ], now: @now)
    end

    assert_equal 1, queries
    summary = summaries.fetch(@app.id)
    assert_equal 15.0, summary.cpu_percent
    assert_equal 150, summary.mem_bytes
    assert_equal [ 10.0, 15.0 ], summary.cpu_points.map(&:last)
    assert_not summaries.key?(stale.id), "nothing in the last 5 minutes"
  end
end
