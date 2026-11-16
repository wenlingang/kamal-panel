# An acknowledged "needs attention" item (AttentionItems). Panel-wide: once someone has said "seen",
# it's seen for everyone, until the same problem starts again.
class DismissedIssue < ApplicationRecord
  belongs_to :user, optional: true

  validates :issue_key, :since, presence: true
end
