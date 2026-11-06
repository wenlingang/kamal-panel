# Alerting (spec 8): evaluating rules into AlertEvents and sending notifications.
#
#   EvaluateAlertRulesJob (every 30 s) → Alerting::Evaluator
#     state rules  → Alerting::StateMachine per (rule, app)
#     event rules  → one firing event per failed deploy / action
#     log rules    → EvaluateLogRuleJob per (rule, app), each running LogQuery → StateMachine
#   any transition that should be heard → Alerting::Notification → DeliverAlertNotificationJob
module Alerting
  # One verdict on a condition. holds: true / false; a nil Check (not this) means "can't tell", and
  # leaves whatever is open untouched: no data is not the same as "fine".
  Check = Data.define(:holds, :message_key, :message_args) do
    def self.holds(message_key, **args) = new(holds: true, message_key:, message_args: args.transform_keys(&:to_s))
    def self.clear = new(holds: false, message_key: nil, message_args: {})

    def holds? = holds
  end
end
