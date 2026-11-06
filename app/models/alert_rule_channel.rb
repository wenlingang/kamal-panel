# Join row: which channels a rule notifies.
class AlertRuleChannel < ApplicationRecord
  belongs_to :alert_rule
  belongs_to :notification_channel
end
