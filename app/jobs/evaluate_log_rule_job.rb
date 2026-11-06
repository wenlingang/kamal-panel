# One log-keyword scan for one (rule, app), scheduled by Alerting::Evaluator. A job of its own so a
# slow SSH session holds up only itself, never the 30-second round of state rules.
class EvaluateLogRuleJob < ApplicationJob
  queue_as :default

  # A scan still running when the next one is due (slow hosts, a long window) makes the next one
  # pointless; drop it rather than stack SSH sessions.
  limits_concurrency to: 1, key: ->(rule, app) { "log_rule_#{rule.id}_#{app.id}" },
                     duration: 10.minutes, on_conflict: :discard

  # The rule or the app went away between scheduling and running: nothing to do.
  discard_on ActiveJob::DeserializationError

  def perform(rule, app)
    rule.reload
    # Rechecked here: the rule may have been edited or disabled, the app deactivated, since the
    # scan was scheduled.
    return unless rule.enabled? && rule.log_keyword? && rule.apps.exists?(app.id)
    return if app.last_poll_error.present?

    Alerting::Broadcast.call([ app.id ]) if Alerting::LogScan.call(rule, app)
  end
end
