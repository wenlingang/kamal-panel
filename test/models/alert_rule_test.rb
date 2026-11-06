require "test_helper"

class AlertRuleTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production")
  end

  test "for_minutes is 0–120 and the condition must be known" do
    assert AlertRule.new(name: "r", condition: "unhealthy", for_minutes: 0).valid?
    assert_not AlertRule.new(name: "r", condition: "unhealthy", for_minutes: 121).valid?
    assert_not AlertRule.new(name: "r", condition: "unhealthy", for_minutes: -1).valid?
    assert_not AlertRule.new(name: "r", condition: "on_fire").valid?
  end

  test "log rules need a keyword, a 1–60 minute window and a threshold of at least 1" do
    rule = AlertRule.new(name: "errors", condition: "log_keyword", keyword: "ERROR", window_minutes: "5", threshold: "3")
    assert_predicate rule, :valid?
    assert_equal 5, rule.window_minutes
    assert_equal 3, rule.threshold
    assert_equal "app", rule.log_source

    assert_not AlertRule.new(name: "e", condition: "log_keyword", keyword: "").valid?
    assert_not AlertRule.new(name: "e", condition: "log_keyword", keyword: "x", window_minutes: 61).valid?
    assert_not AlertRule.new(name: "e", condition: "log_keyword", keyword: "x", threshold: 0).valid?
    assert_not AlertRule.new(name: "e", condition: "log_keyword", keyword: "x", threshold: "abc").valid?
    assert_not AlertRule.new(name: "e", condition: "log_keyword", keyword: "a\nb").valid?
  end

  test "defaults fill in the window and threshold" do
    rule = AlertRule.create!(name: "e", condition: "log_keyword", keyword: "x")
    assert_equal AlertRule::DEFAULT_WINDOW_MINUTES, rule.window_minutes
    assert_equal 1, rule.threshold
  end

  test "a log source other than app needs one app, and must be one of its sources" do
    assert_not AlertRule.new(name: "e", condition: "log_keyword", keyword: "x", log_source: "proxy").valid?
    assert AlertRule.new(name: "e", condition: "log_keyword", keyword: "x", log_source: "proxy", managed_app: @app).valid?
    assert_not AlertRule.new(name: "e", condition: "log_keyword", keyword: "x", log_source: "accessory:nope", managed_app: @app).valid?
  end

  test "switching away from a log rule drops its log settings" do
    rule = AlertRule.create!(name: "e", condition: "log_keyword", keyword: "x")
    rule.update!(condition: "drift")
    assert_equal({}, rule.params)
  end

  test "disabling or changing a rule closes its open events silently" do
    rule = AlertRule.create!(name: "u", condition: "unhealthy")
    firing = rule.alert_events.create!(managed_app: @app, state: "firing", message_key: "unhealthy",
                                       started_at: 5.minutes.ago, fired_at: 3.minutes.ago)

    assert_no_enqueued_jobs(only: DeliverAlertNotificationJob) { rule.update!(enabled: false) }

    assert_predicate firing.reload, :resolved?
  end

  test "apps: one app, or every active one" do
    other = ManagedApp.create!(name: "shop", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production")
    other.deactivate!

    assert_equal [ @app ], AlertRule.new(managed_app: @app).apps.to_a
    assert_equal [ @app ], AlertRule.new.apps.to_a
  end

  include ActiveJob::TestHelper

  test "resource rules take a 1–100 percentage threshold, 90 by default, and keep only that" do
    rule = AlertRule.create!(name: "mem", condition: "memory_high", metric_threshold: "85", keyword: "x")
    assert_equal({ "threshold" => 85 }, rule.reload.params)
    assert_equal 85, rule.metric_threshold
    assert_predicate rule, :state_condition?

    assert_equal 90, AlertRule.create!(name: "disk", condition: "host_disk_high").metric_threshold
    assert_not AlertRule.new(name: "c", condition: "cpu_high", metric_threshold: 0).valid?
    assert_not AlertRule.new(name: "c", condition: "cpu_high", metric_threshold: 101).valid?
    assert_not AlertRule.new(name: "c", condition: "cpu_high", metric_threshold: "lots").valid?
  end

  test "a log rule's count and a resource rule's percentage don't overwrite each other on the form" do
    rule = AlertRule.create!(name: "cpu", condition: "cpu_high", threshold: "3", metric_threshold: "75")
    assert_equal 75, rule.reload.metric_threshold

    log = AlertRule.create!(name: "log", condition: "log_keyword", keyword: "ERROR", threshold: "3", metric_threshold: "75")
    assert_equal 3, log.reload.threshold
  end
end
