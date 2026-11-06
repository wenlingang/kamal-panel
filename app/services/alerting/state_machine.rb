module Alerting
  # pending → firing → resolved for one (rule, app), given this round's Check (spec 8):
  #
  #   holds, nothing open        → pending since now (firing at once when for_minutes is 0)
  #   holds, pending long enough → firing, notify
  #   holds, firing              → remind at most every AlertEvent::RENOTIFY_AFTER
  #   clear, pending             → dropped silently (it never alerted)
  #   clear, firing              → resolved, notify recovery
  #   nil (can't tell)           → nothing changes
  #
  # Safe to run twice at once: the open-event unique index refuses a second pending row, and the
  # AlertEvent transitions are compare-and-set, so only one caller notifies.
  class StateMachine
    def self.apply(...) = new(...).apply

    def initialize(rule, app, check, now: Time.current)
      @rule = rule
      @app = app
      @check = check
      @now = now
    end

    # Returns true when something visible changed (an event opened, fired, resolved or went away).
    def apply
      return false if check.nil?

      check.holds? ? holding : cleared
    end

    private
      attr_reader :rule, :app, :check, :now

      def open_event
        @open_event ||= AlertEvent.unresolved.find_by(alert_rule: rule, managed_app: app, dedupe_key: nil)
      end

      def holding
        event = open_event
        if event.nil?
          event = open_pending
          return false if event.nil?

          fire(event) if due?(event)
          return true
        end

        refresh_message(event)
        if event.pending?
          due?(event) ? fire(event) : false
        else
          Notification.enqueue(event, "reminder") if event.remind!(now)
          false
        end
      end

      def cleared
        event = open_event
        return false if event.nil?

        if event.pending?
          event.close_silently!(now)
        elsif event.resolve!(now)
          Notification.enqueue(event, "resolved")
          true
        else
          false
        end
      end

      def open_pending
        AlertEvent.create!(alert_rule: rule, managed_app: app, state: "pending", started_at: now,
                           message_key: check.message_key, message_args: check.message_args)
      rescue ActiveRecord::RecordNotUnique
        # An overlapping evaluation opened it first; it owns this round.
        nil
      end

      def due?(event) = event.started_at <= now - rule.for_minutes.minutes

      def fire(event)
        return false unless event.fire!(now)

        Notification.enqueue(event, "firing")
        true
      end

      # The condition may hold for a new reason (other versions drifting, a higher count): keep
      # the message current so the page and the next reminder say what is true now.
      def refresh_message(event)
        return if event.message_key == check.message_key && event.message_args == check.message_args

        event.update_columns(message_key: check.message_key, message_args: check.message_args, updated_at: now)
      end
  end
end
