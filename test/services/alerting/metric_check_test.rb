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

  test "cpu_high: mean over the app's containers and the last 3 minutes, proxy left out" do
    cpu = rule("cpu_high", threshold: 50)
    container(@now - 2.minutes, cpu: 70)
    container(@now - 2.minutes, cpu: 30, name: "blog-worker-production-a")  # sample mean 50
    container(@now - 1.minute, cpu: 60)
    container(@now - 1.minute, cpu: 50, name: "blog-worker-production-a")  # sample mean 55
    container(@now - 1.minute, cpu: 0, kind: "proxy", name: "kamal-proxy")
    container(@now - 10.minutes, cpu: 0)                                     # outside the window

    verdict = check(cpu)
    assert_predicate verdict, :holds?
    assert_equal "cpu_high", verdict.message_key
    assert_equal({ "percent" => 52.5, "threshold" => 50 }, verdict.message_args)

    assert_not check(rule("cpu_high", threshold: 60)).holds?
  end

  test "memory_high: any container's latest share" do
    container(@now - 3.minutes, mem_percent: 95)
    container(@now - 1.minute, mem_percent: 70)
    container(@now - 1.minute, mem_percent: 91, name: "blog-worker-production-a")

    verdict = check(rule("memory_high", threshold: 90))
    assert_predicate verdict, :holds?
    assert_equal "blog-worker-production-a", verdict.message_args["container"]
    assert_not check(rule("memory_high", threshold: 92)).holds?, "the 95% reading was superseded"
  end

  test "host rules ignore another app's samples for the same host string" do
    # Another app naming "127.0.0.1" may reach a different machine (its own port/proxy/user), so
    # its readings must neither raise nor mask this app's host alerts.
    other = ManagedApp.create!(name: "other", config_yaml: file_fixture("simple_deploy.yml").read, destination: "staging")
    HostMetric.create!(managed_app: other, host: "127.0.0.1", mem_total_bytes: 100, mem_available_bytes: 0,
                       sampled_at: @now - 1.minute)

    assert_nil check(rule("host_memory_high", threshold: 90))

    host(@now - 1.minute, mem_used: 0.95, disk_used: 0.42)
    assert_predicate check(rule("host_memory_high", threshold: 90)), :holds?
  end

  test "host rules: the worst of the app's hosts" do
    host(@now - 1.minute, mem_used: 0.93, disk_used: 0.42)
    HostMetric.create!(managed_app: @app, host: "10.9.9.9", mem_total_bytes: 100, mem_available_bytes: 0, sampled_at: @now - 1.minute) # not this app's

    assert_predicate check(rule("host_memory_high", threshold: 90)), :holds?
    assert_equal "127.0.0.1", check(rule("host_memory_high", threshold: 90)).message_args["host"]
    assert_not check(rule("host_disk_high", threshold: 90)).holds?
  end

  test "no recent sample is no verdict, never a clear" do
    container(@now - 10.minutes, cpu: 99, mem_percent: 99)
    host(@now - 10.minutes, mem_used: 0.99, disk_used: 0.99)

    %w[cpu_high memory_high host_memory_high host_disk_high].each do |condition|
      assert_nil check(rule(condition)), condition
    end
  end

  test "through the evaluator: pending, firing after for_minutes, untouched while data is missing, resolved when it drops" do
    memory = rule("memory_high", threshold: 90, for_minutes: 2)
    start = @now

    container(start - 30.seconds, mem_percent: 95)
    Alerting::Evaluator.call(now: start)
    event = AlertEvent.where(alert_rule: memory).sole
    assert_predicate event, :pending?

    container(start + 2.minutes, mem_percent: 96)
    Alerting::Evaluator.call(now: start + 2.minutes + 30.seconds)
    assert_predicate event.reload, :firing?
    assert_equal "memory_high", event.message_key

    # Collection stops: the alert stays as it is.
    Alerting::Evaluator.call(now: start + 20.minutes)
    assert_predicate event.reload, :firing?

    container(start + 21.minutes, mem_percent: 40)
    Alerting::Evaluator.call(now: start + 21.minutes + 10.seconds)
    assert_predicate event.reload, :resolved?
    assert_includes event.message, "blog-web-production-a"
  end

  test "an app whose config is broken gets no metric verdict" do
    memory = rule("memory_high")
    container(@now, mem_percent: 99)
    @app.update_columns(last_poll_error: "boom")

    assert_nil Alerting::Evaluator.new(now: @now).state_check(memory, @app)
  end
end
