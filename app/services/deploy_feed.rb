# The global deploy page's list: every deploy attempt the panel knows of, newest first.
#
# Two sources. DeployEvent covers hook reports, inferred convergences and the panel's own deploys
# and rollbacks. Audit rows add panel deploys / rollbacks that have no event: refused by the deploy
# lock (never ran), still queued, or older than panel events.
class DeployFeed
  LIMIT = 100
  DEPLOY_ACTIONS = %w[deploy rollback].freeze

  # result: :success / :failure / :running / :unfinished / :not_run
  Entry = Data.define(:managed_app, :version, :source, :command, :performer, :result, :at, :audit_log)

  def initialize(apps)
    @apps = apps
  end

  def entries
    (event_entries + audit_entries).sort_by(&:at).reverse.first(LIMIT)
  end

  private
    attr_reader :apps

    def event_entries
      DeployEvent.where(managed_app: apps).includes({ managed_app: :git_connection }, :audit_log)
                 .order(created_at: :desc).limit(LIMIT).map do |event|
        Entry.new(managed_app: event.managed_app, version: event.version, source: event.source,
                  command: event.command, performer: event.performer, result: event_result(event),
                  at: event.started_at || event.succeeded_at || event.created_at, audit_log: event.audit_log)
      end
    end

    def audit_entries
      AuditLog.where(managed_app: apps, action_name: DEPLOY_ACTIONS)
              .where.not(id: DeployEvent.where.not(audit_log_id: nil).select(:audit_log_id))
              .includes({ managed_app: :git_connection }, :user)
              .order(created_at: :desc).limit(LIMIT).map do |log|
        Entry.new(managed_app: log.managed_app, version: log.target_version, source: "panel",
                  command: log.action_name, performer: log.user&.display_name, result: audit_result(log),
                  at: log.created_at, audit_log: log)
      end
    end

    # A hook row that never got its success report is DeployAlerts' "unfinished" once it is old
    # enough; before that it is simply still running.
    def event_result(event)
      result = event.result
      return :unfinished if result == :running && !event.panel? &&
                            event.started_at && event.started_at < DeployEvent::UNFINISHED_AFTER.ago

      result
    end

    # Without an event, a finished failure is one that never ran (the lock refused it, or it
    # crashed before starting); a pending one is queued, or was cut off.
    def audit_result(log)
      case log.result
      when "success" then :success
      when "failure" then :not_run
      else log.interrupted? ? :failure : :running
      end
    end
end
