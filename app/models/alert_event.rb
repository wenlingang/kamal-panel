# One occurrence of a rule's condition on one app (spec 8): pending (holding, not yet for long
# enough) → firing (notified) → resolved (notified again for state conditions).
#
# Every transition is a compare-and-set UPDATE on the state it expects to leave: when two
# evaluations overlap, exactly one of them wins the transition, so exactly one sends the
# notification. Together with the partial unique indexes on the table (one open event per rule and
# app; one event per source record) that is the guard against double alerts.
class AlertEvent < ApplicationRecord
  STATES = %w[pending firing resolved].freeze
  OPEN_STATES = %w[pending firing].freeze
  # A firing event is notified again at most this often while it keeps firing (spec 8).
  RENOTIFY_AFTER = 60.minutes

  belongs_to :alert_rule
  belongs_to :managed_app

  validates :state, inclusion: { in: STATES }
  validates :message_key, presence: true

  scope :unresolved, -> { where(state: OPEN_STATES) }
  scope :pending, -> { where(state: "pending") }
  scope :firing, -> { where(state: "firing") }
  scope :resolved, -> { where(state: "resolved") }
  scope :recent_first, -> { order(started_at: :desc, id: :desc) }

  def pending? = state == "pending"
  def firing? = state == "firing"
  def resolved? = state == "resolved"
  def open? = OPEN_STATES.include?(state)

  # Rendered when shown or sent, in the reader's language (notifications use the default locale).
  def message(locale: I18n.locale)
    args = message_args.to_h.symbolize_keys
    # An action is stored by name (like audit rows) and named in the reader's language.
    args[:action] = I18n.t("audit.actions.#{args[:action_name]}", locale:, default: args[:action_name].to_s) if args.key?(:action_name)
    I18n.t("alert_events.messages.#{message_key}", **args, locale:)
  end

  # Each returns true only for the caller that actually made the transition.
  def fire!(now = Time.current)
    transition!(from: "pending", to: "firing", fired_at: now, last_notified_at: now, updated_at: now)
  end

  def resolve!(now = Time.current)
    transition!(from: "firing", to: "resolved", resolved_at: now, updated_at: now)
  end

  # Claims the right to send a reminder; false when it's not due or someone else just claimed it.
  def remind!(now = Time.current)
    return false unless firing? && last_notified_at && last_notified_at <= now - RENOTIFY_AFTER

    claimed = self.class.where(id:, state: "firing", last_notified_at:)
                        .update_all(last_notified_at: now, updated_at: now)
    reload if claimed == 1
    claimed == 1
  end

  # Ends an event without telling anyone: a pending one never alerted, so it just goes away; a
  # firing one whose rule changed or was disabled (or whose app was deactivated) is marked resolved.
  def close_silently!(now = Time.current)
    if pending?
      self.class.where(id:, state: "pending").delete_all == 1
    else
      transition!(from: "firing", to: "resolved", resolved_at: now, updated_at: now)
    end
  end

  def duration(now = Time.current) = (resolved_at || now) - (fired_at || started_at)

  private
    def transition!(from:, to:, **attributes)
      changed = self.class.where(id:, state: from).update_all(state: to, **attributes)
      reload if changed == 1
      changed == 1
    end
end
