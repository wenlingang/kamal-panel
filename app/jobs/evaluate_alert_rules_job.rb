# Recurring (config/recurring.yml, every 30 seconds): one round of alert evaluation (spec 8).
#
# Solid Queue can start a recurrence while the previous one is still running. limits_concurrency
# discards the overlapping one; should two still run at once (a lock past its duration, another
# adapter), the unique indexes on alert_events and the compare-and-set transitions in AlertEvent
# keep it to one event and one notification.
class EvaluateAlertRulesJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: "evaluate_alert_rules", duration: 5.minutes, on_conflict: :discard

  def perform
    Alerting::Evaluator.call
  end
end
