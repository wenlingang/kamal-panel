require "test_helper"

class Alerting::EvaluatorTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Rails.cache.clear
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production")
    @channel = NotificationChannel.create!(name: "hook", kind: "webhook", target: "https://hooks.example.com/x")
    @rule = AlertRule.create!(name: "不健康", condition: "unhealthy", for_minutes: 2, notification_channels: [ @channel ])
    @start = Time.current.change(usec: 0)
  end

  # One collection round at `at`: the web and worker containers on the app's only host.
  def observe(at, health: "healthy", version: "aaa1111", reachable: true)
    %w[web worker].each do |role|
      Observation.create!(managed_app: @app, host: "127.0.0.1", role:, reachable:,
                          version: (version if reachable), docker_status: ("running" if reachable),
                          container_name: ("blog-#{role}-production-#{version}" if reachable),
                          health: (role == "web" ? health : nil), observed_at: at)
    end
  end

  # Collect, then evaluate, both at `at` (the status reads "stale" against the wall clock).
  def round(at, **observation)
    travel_to(at) do
      observe(at, **observation)
      Alerting::Evaluator.call(now: at)
    end
  end

  def event = AlertEvent.where(alert_rule: @rule).sole
  def deliveries(kind) = enqueued_jobs.count { |job| job["job_class"] == "DeliverAlertNotificationJob" && job["arguments"].last == kind }

  test "a condition that holds goes pending, fires after for_minutes, and resolves when it clears" do
    round(@start, health: "unhealthy")
    assert_predicate event, :pending?
    assert_equal 0, deliveries("firing")

    round(@start + 1.minute, health: "unhealthy")
    assert_predicate event, :pending?, "for_minutes (2) hasn't passed yet"

    round(@start + 2.minutes, health: "unhealthy")
    assert_predicate event, :firing?
    assert_equal @start + 2.minutes, event.fired_at
    assert_equal 1, deliveries("firing")
    assert_equal I18n.t("alert_events.messages.unhealthy"), event.message

    round(@start + 3.minutes, health: "healthy")
    assert_predicate event, :resolved?
    assert_equal 1, deliveries("resolved")
  end

  # Overlapping rounds: the database refuses a second open event, and only one caller wins each
  # transition — so only one of them notifies.
  test "transitions are compare-and-set and the open event is unique" do
    round(@start, health: "unhealthy")
    pending = event
    stale_copy = AlertEvent.find(pending.id)

    assert pending.fire!(@start + 3.minutes)
    assert_not stale_copy.fire!(@start + 3.minutes)

    assert_raises(ActiveRecord::RecordNotUnique) do
      AlertEvent.create!(alert_rule: @rule, managed_app: @app, state: "pending", message_key: "unhealthy", started_at: @start)
    end
  end

  # ── Event conditions ──────────────────────────────────────────────────────────────────────────

  test "a failed deploy fires once, immediately, and resolves on the next successful deploy" do
    rule = AlertRule.create!(name: "发布失败", condition: "deploy_failed", for_minutes: 5, notification_channels: [ @channel ],
                            created_at: @start - 1.hour)
    travel_to(@start) do
      DeployEvent.create!(managed_app: @app, version: "bad0001", source: "panel", started_at: @start - 2.minutes, failed_at: @start - 1.minute)

      Alerting::Evaluator.call(now: @start)
      Alerting::Evaluator.call(now: @start + 30.seconds)
    end

    event = AlertEvent.find_by!(alert_rule: rule)
    assert_predicate event, :firing?
    assert_includes event.message, "bad0001"
    assert_equal 1, deliveries("firing"), "the same failure notifies once"

    travel_to(@start + 5.minutes) do
      DeployEvent.create!(managed_app: @app, version: "good002", source: "panel", started_at: @start + 3.minutes,
                          succeeded_at: @start + 4.minutes)
      Alerting::Evaluator.call(now: @start + 5.minutes)
    end
    assert_predicate event.reload, :resolved?
    assert_equal 0, deliveries("resolved")
  end

  # ── Log rules: scheduled here, scanned elsewhere ───────────────────────────────────────────────
end
