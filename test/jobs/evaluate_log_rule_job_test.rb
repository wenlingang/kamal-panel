require "test_helper"

class EvaluateLogRuleJobTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production")
    @rule = AlertRule.create!(name: "ERROR", condition: "log_keyword", keyword: "ERROR")
  end

  test "scans an enabled rule (no credential here, so the rule records why it read nothing)" do
    EvaluateLogRuleJob.perform_now(@rule, @app)

    assert_includes @rule.reload.last_error, "no_credential"
  end

  test "skips a rule disabled or turned into something else since it was scheduled" do
    @rule.update!(enabled: false)
    EvaluateLogRuleJob.perform_now(@rule, @app)

    # A scan would have run LogQuery, which (no SSH credential here) records why it read nothing.
    assert_nil @rule.reload.last_error
  end

  test "skips an app whose config no longer parses" do
    @app.update_columns(last_poll_error: "boom")
    EvaluateLogRuleJob.perform_now(@rule, @app)

    # A scan would have run LogQuery, which (no SSH credential here) records why it read nothing.
    assert_nil @rule.reload.last_error
  end
end
