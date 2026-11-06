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

  test "a pending event that clears before for_minutes just goes away, unnotified" do
    round(@start, health: "unhealthy")
    round(@start + 1.minute, health: "healthy")

    assert_equal 0, AlertEvent.count
    assert_equal 0, enqueued_jobs.size
  end

  test "for_minutes 0 fires on the first round" do
    @rule.update!(for_minutes: 0)

    round(@start, health: "unhealthy")

    assert_predicate event, :firing?
    assert_equal 1, deliveries("firing")
  end

  test "a firing event is re-notified at most once an hour" do
    @rule.update!(for_minutes: 0)
    round(@start, health: "unhealthy")

    round(@start + 30.minutes, health: "unhealthy")
    assert_equal 0, deliveries("reminder")

    round(@start + 61.minutes, health: "unhealthy")
    assert_equal 1, deliveries("reminder")

    round(@start + 62.minutes, health: "unhealthy")
    assert_equal 1, deliveries("reminder")
  end

  test "an app never collected has no verdict" do
    travel_to(@start) { Alerting::Evaluator.call(now: @start) }

    assert_equal 0, AlertEvent.count
  end

  test "can't-tell leaves a firing event as it is" do
    @rule.update!(for_minutes: 0)
    round(@start, health: "unhealthy")
    Observation.delete_all

    travel_to(@start + 1.minute) { Alerting::Evaluator.call(now: @start + 1.minute) }

    assert_predicate event, :firing?
  end

  test "drift and unreachable rules see their own condition, and say which versions / hosts" do
    drift = AlertRule.create!(name: "漂移", condition: "drift", for_minutes: 0)
    down = AlertRule.create!(name: "不可达", condition: "unreachable", for_minutes: 0)

    travel_to(@start) do
      Observation.create!(managed_app: @app, host: "127.0.0.1", role: "web", version: "aaa1111", docker_status: "running",
                          container_name: "blog-web-production-aaa1111", reachable: true, observed_at: @start)
      Observation.create!(managed_app: @app, host: "127.0.0.1", role: "worker", version: "bbb2222", docker_status: "running",
                          container_name: "blog-worker-production-bbb2222", reachable: true, observed_at: @start)
      Alerting::Evaluator.call(now: @start)
    end
    assert_includes AlertEvent.find_by!(alert_rule: drift).message, "aaa1111, bbb2222"
    assert_not AlertEvent.exists?(alert_rule: down)

    round(@start + 1.minute, reachable: false)
    assert_includes AlertEvent.find_by!(alert_rule: down).message, "127.0.0.1"
  end

  # The config can't be parsed: nothing may touch parsed_config. "unreachable" rules fire (the panel
  # can't see the app); the others can't tell and stay as they were.
  test "a broken config fires unreachable rules and leaves the others alone" do
    down = AlertRule.create!(name: "不可达", condition: "unreachable", for_minutes: 0)
    @app.update_columns(last_poll_error: "YAML syntax error at line 3\nmore", first_poll_error_at: @start)

    travel_to(@start) { Alerting::Evaluator.call(now: @start) }

    event = AlertEvent.find_by!(alert_rule: down)
    assert_predicate event, :firing?
    assert_includes event.message, "YAML syntax error at line 3"
    assert_not AlertEvent.exists?(alert_rule: @rule)
  end

  test "disabled rules and deactivated apps close their events silently" do
    @rule.update!(for_minutes: 0)
    round(@start, health: "unhealthy")
    clear_enqueued_jobs
    @app.deactivate!

    travel_to(@start + 1.minute) { Alerting::Evaluator.call(now: @start + 1.minute) }

    assert_predicate event, :resolved?
    assert_equal 0, enqueued_jobs.size
  end

  test "only enabled channels are notified" do
    @channel.update!(enabled: false)
    @rule.update!(for_minutes: 0)

    round(@start, health: "unhealthy")

    assert_predicate event, :firing?
    assert_equal 0, deliveries("firing")
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

  test "a hook deploy that never reported back counts as failed" do
    rule = AlertRule.create!(name: "发布失败", condition: "deploy_failed", created_at: @start - 1.hour)
    travel_to(@start) do
      DeployEvent.create!(managed_app: @app, version: "lost003", source: "hook", started_at: @start - 20.minutes)
      Alerting::Evaluator.call(now: @start)
    end

    assert_equal "deploy_unfinished", AlertEvent.find_by!(alert_rule: rule).message_key
  end

  test "failures older than the rule don't page anyone" do
    travel_to(@start) do
      DeployEvent.create!(managed_app: @app, version: "old0001", source: "panel", started_at: @start - 2.hours, failed_at: @start - 1.hour)
      AlertRule.create!(name: "发布失败", condition: "deploy_failed")
      Alerting::Evaluator.call(now: @start)
    end

    assert_equal 0, AlertEvent.count
  end

  test "a failed action fires per audit row; deploys are left to deploy_failed" do
    rule = AlertRule.create!(name: "操作失败", condition: "action_failed", notification_channels: [ @channel ],
                            created_at: @start - 1.hour)
    travel_to(@start) do
      AuditLog.create!(user: users(:two), managed_app: @app, action_name: "restart", hosts: [], result: "failure",
                       created_at: @start - 1.minute, finished_at: @start - 1.minute)
      AuditLog.create!(user: users(:two), managed_app: @app, action_name: "deploy", hosts: [], result: "failure",
                       created_at: @start - 1.minute, finished_at: @start - 1.minute)
      Alerting::Evaluator.call(now: @start)
    end

    event = AlertEvent.where(alert_rule: rule).sole
    assert_includes event.message, I18n.t("audit.actions.restart")
    assert_equal 1, deliveries("firing")

    travel_to(@start + 2.minutes) do
      AuditLog.create!(user: users(:two), managed_app: @app, action_name: "restart", hosts: [], result: "success",
                       created_at: @start + 1.minute, finished_at: @start + 1.minute)
      Alerting::Evaluator.call(now: @start + 2.minutes)
    end
    assert_predicate event.reload, :resolved?
  end

  # ── Log rules: scheduled here, scanned elsewhere ───────────────────────────────────────────────

  test "log rules get one scan per window, per app" do
    rule = AlertRule.create!(name: "ERROR", condition: "log_keyword", keyword: "ERROR", window_minutes: 5)

    assert_enqueued_jobs 1, only: EvaluateLogRuleJob do
      Alerting::Evaluator.call(now: @start)
      Alerting::Evaluator.call(now: @start + 30.seconds)
    end
    assert_equal @start, rule.reload.last_evaluated_at

    assert_enqueued_jobs 1, only: EvaluateLogRuleJob do
      Alerting::Evaluator.call(now: @start + 5.minutes)
    end
  end
end
