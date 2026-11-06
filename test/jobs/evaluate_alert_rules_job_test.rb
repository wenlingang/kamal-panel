require "test_helper"

class EvaluateAlertRulesJobTest < ActiveSupport::TestCase
  test "is scheduled every 30 seconds in every environment that runs recurring tasks" do
    config = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    %w[production development].each do |env|
      task = config.fetch(env).fetch("evaluate_alert_rules")
      assert_equal "EvaluateAlertRulesJob", task["class"]
      assert_equal "every 30 seconds", task["schedule"]
    end
  end

  # Overlapping recurrences are dropped by Solid Queue rather than queued behind each other.
  test "allows one evaluation at a time" do
    assert_equal 1, EvaluateAlertRulesJob.concurrency_limit
    assert_equal :discard, EvaluateAlertRulesJob.concurrency_on_conflict
  end
end
