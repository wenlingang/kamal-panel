module Alerting
  # One evaluation round over every enabled rule (EvaluateAlertRulesJob, every 30 s). Cheap by
  # design: state rules read the latest observations already in the database, event rules read
  # deploy events and audit rows. Nothing here talks to a host; log rules only get their scan
  # scheduled (EvaluateLogRuleJob does the SSH).
  class Evaluator
    # Event rules look back this far, and an unresolved event of theirs closes after this long:
    # a failure from yesterday is history, not something to page anyone about now.
    EVENT_LOOKBACK = 24.hours

    def self.call(...) = new(...).call

    def initialize(now: Time.current)
      @now = now
      @statuses = {}
      @changed_app_ids = Set.new
    end

    # Returns the ids of apps whose alerts changed (for the broadcast).
    def call
      close_out_of_scope

      AlertRule.enabled.includes(:managed_app).find_each do |rule|
        if rule.state_condition?
          rule.apps.each { |app| changed!(app) if StateMachine.apply(rule, app, state_check(rule, app), now:) }
        elsif rule.event_condition?
          evaluate_events(rule)
        elsif rule.log_keyword?
          schedule_log_scan(rule)
        end
      end

      Broadcast.call(changed_app_ids) if changed_app_ids.any?
      changed_app_ids
    end

    # The verdict for a state condition on one app; nil when there's nothing to judge from.
    def state_check(rule, app)
      # A deploy.yml that doesn't parse must not reach parsed_config (it raises). The panel then
      # can't see the app at all, which is what "unreachable" rules are for; the other conditions
      # can't be judged and stay as they were.
      if app.last_poll_error.present?
        return nil unless rule.condition == "unreachable"

        return Check.holds("config_broken", error: app.last_poll_error.to_s.lines.first.to_s.strip.truncate(200))
      end

      # Usage rules read the metrics rows, not the status poll; they judge their own staleness.
      return MetricCheck.call(rule, app, now:) if rule.metric_condition?

      status = (@statuses[app.id] ||= ManagedAppStatus.new(app))
      # Never collected yet (just onboarded): no data, no verdict.
      return nil if status.level == :unknown

      case rule.condition
      when "unhealthy"
        status.unhealthy? ? Check.holds("unhealthy") : Check.clear
      when "drift"
        status.drift? ? Check.holds("drift", versions: status.versions.join(", ")) : Check.clear
      when "unreachable"
        return Check.clear unless status.unreachable_or_stale?

        hosts = status.unreachable_hosts
        hosts.any? ? Check.holds("unreachable", hosts: hosts.join(", ")) : Check.holds("stale")
      end
    end

    private
      attr_reader :now, :changed_app_ids

      def changed!(app_or_id) = changed_app_ids << (app_or_id.is_a?(ManagedApp) ? app_or_id.id : app_or_id)

      # A disabled rule or a deactivated app leaves nothing open behind it. Bookkeeping only:
      # nobody asked to hear about it.
      def close_out_of_scope
        AlertEvent.unresolved.joins(:alert_rule, :managed_app)
                  .where("alert_rules.enabled = ? OR managed_apps.deactivated_at IS NOT NULL", false)
                  .find_each { |event| changed!(event.managed_app_id) if event.close_silently!(now) }
      end

      # ── Event conditions: one firing event per failed deploy / action ──────────────────────

      def evaluate_events(rule)
        apps = rule.apps.to_a
        since = [ rule.created_at, now - EVENT_LOOKBACK ].max

        failures(rule, apps, since).each do |failure|
          next if AlertEvent.exists?(alert_rule: rule, dedupe_key: failure[:key])

          event = open_firing(rule, failure)
          next if event.nil?

          Notification.enqueue(event, "firing")
          changed!(event.managed_app_id)
        end

        resolve_recovered(rule)
      end

      def failures(rule, apps, since)
        rule.condition == "deploy_failed" ? deploy_failures(apps, since) : action_failures(apps, since)
      end

      # Panel deploys that failed, and (hook-reported) deploys that started and never reported back:
      # Kamal has no failure hook, so silence past DeployEvent::UNFINISHED_AFTER is how a failed CI
      # deploy shows up (the same reading as DeployAlerts' "unfinished").
      def deploy_failures(apps, since)
        failed = DeployEvent.where(managed_app: apps).where(failed_at: since..).map do |event|
          { key: "deploy_event:#{event.id}", app_id: event.managed_app_id, at: event.failed_at,
            message_key: "deploy_failed", args: { version: event.version } }
        end

        unfinished = DeployEvent.where(managed_app: apps).not_failed
                                .where(succeeded_at: nil)
                                .where(started_at: (since - DeployEvent::UNFINISHED_AFTER)..(now - DeployEvent::UNFINISHED_AFTER))
                                .map do |event|
          { key: "deploy_event:#{event.id}", app_id: event.managed_app_id, at: event.started_at,
            message_key: "deploy_unfinished",
            args: { version: event.version, minutes: (DeployEvent::UNFINISHED_AFTER / 60).to_i } }
        end

        (failed + unfinished).reject { |failure| deploy_succeeded_since?(failure[:app_id], failure[:at]) }
      end

      # Deploys and rollbacks are left to deploy_failed rules (they record a DeployEvent), so one
      # failed deploy doesn't page twice.
      def action_failures(apps, since)
        AuditLog.where(managed_app: apps, result: "failure", action_name: watched_actions)
                .where(finished_at: since..).map do |log|
          { key: "audit_log:#{log.id}", app_id: log.managed_app_id, at: log.finished_at,
            message_key: "action_failed",
            args: { action_name: log.action_name, user: log.user&.display_name.to_s } }
        end.reject { |failure| action_succeeded_since?(failure[:app_id], failure[:args][:action_name], failure[:at]) }
      end

      def watched_actions
        @watched_actions ||= Actions::Base.all.select { |action| action.mutating? && !action.records_deploy_event? }
                                          .map(&:action_name)
      end

      def open_firing(rule, failure)
        AlertEvent.create!(alert_rule: rule, managed_app_id: failure[:app_id], state: "firing",
                           dedupe_key: failure[:key], message_key: failure[:message_key],
                           message_args: failure[:args].transform_keys(&:to_s),
                           started_at: failure[:at], fired_at: now, last_notified_at: now)
      rescue ActiveRecord::RecordNotUnique
        nil
      end

      # An event-type alert ends when the same thing next succeeds on that app (or after
      # EVENT_LOOKBACK). Not notified: the failure was the news.
      def resolve_recovered(rule)
        AlertEvent.firing.where(alert_rule: rule).where.not(dedupe_key: nil).find_each do |event|
          recovered =
            event.started_at < now - EVENT_LOOKBACK ||
            if rule.condition == "deploy_failed"
              deploy_succeeded_since?(event.managed_app_id, event.started_at)
            else
              action_succeeded_since?(event.managed_app_id, event.message_args["action_name"], event.started_at)
            end

          changed!(event.managed_app_id) if recovered && event.close_silently!(now)
        end
      end

      def deploy_succeeded_since?(app_id, time)
        DeployEvent.where(managed_app_id: app_id).not_failed.where("succeeded_at > ?", time).exists?
      end

      def action_succeeded_since?(app_id, action_name, time)
        AuditLog.where(managed_app_id: app_id, action_name:, result: "success").where("finished_at > ?", time).exists?
      end

      # ── Log rules: claim the scan, hand the SSH to a job per app ──────────────────────────────

      # The claim is a compare-and-set on last_evaluated_at, so overlapping rounds schedule one scan.
      def schedule_log_scan(rule)
        return unless rule.log_scan_due?(now)

        claimed = AlertRule.where(id: rule.id, last_evaluated_at: rule.last_evaluated_at)
                           .update_all(last_evaluated_at: now)
        return unless claimed == 1

        rule.apps.each { |app| EvaluateLogRuleJob.perform_later(rule, app) }
      end
  end
end
