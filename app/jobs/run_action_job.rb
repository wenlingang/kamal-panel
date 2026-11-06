# Run an action.
class RunActionJob < ApplicationJob
  queue_as :default

  def perform(audit_log_id)
    log = AuditLog.find(audit_log_id)
    app = log.managed_app
    action = Actions::Base.find(log.action_name).new(app, target_version: log.target_version,
                                                                target: log.target)
    started = Time.current

    return if action.class.requires_lock? && !lock_free?(app, log, started)

    # Opened only once the run really starts: an attempt the lock refused never happened, and its
    # audit row already says so.
    event = start_deploy_event(app, log, action, started)

    output = +""

    result = KamalCli::Invocation.new(app).run(action.cli_args) do |line|
      output << line << "\n"
      broadcast_line(log, line)
    end
    status = result[:status]

    log.finish!(result: status.zero? ? "success" : "failure",
                command: "kamal #{action.cli_args.join(' ')}",
                output_digest: result[:output],
                duration_ms: ((Time.current - started) * 1000).round)
    finish_deploy_event(event, success: status.zero?)
    broadcast_result(log)

    # Do not take the command's exit code as the conclusion (spec 8.4): trigger burst polling and
    # confirm with a new Observation.
    PollCadence.mark_burst!(app)
    PollManagedAppJob.perform_later(app)
  rescue StandardError => e
    # Anything that escapes here (no SSH key, an unreadable config...) would otherwise leave the
    # audit row pending forever and the action page saying "running" forever. Close it as a
    # failure with the reason; no retry, since re-running a deploy action unasked is worse.
    # An unknown action name means the closed action set was bypassed: that stays loud.
    raise if log.nil? || e.is_a?(Actions::Base::UnknownAction)

    Rails.logger.error("[action] 执行出错：#{e.class}: #{e.message}")
    finish_blocked(log, started || Time.current, "执行出错：#{e.message}") if log.reload.result == "pending"
    finish_deploy_event(event, success: false) if event && event.reload.result == :running
  end

  private
    def start_deploy_event(app, log, action, started)
      return nil unless action.class.records_deploy_event?

      app.deploy_events.create!(
        source: "panel", version: log.target_version, destination: app.destination,
        performer: log.user.display_name, command: log.action_name,
        started_at: started, audit_log: log
      )
    end

    # The CLI's exit code decides the row's outcome, but not whether the version is running: that
    # is still for the next observation to confirm (observed_at, via the Reconciler).
    def finish_deploy_event(event, success:)
      return if event.nil?

      success ? event.update!(succeeded_at: Time.current) : event.update!(failed_at: Time.current)
    end

    def lock_free?(app, log, started)
      lock = KamalLock.new(app).status

      if lock[:error]
        finish_blocked(log, started, "锁状态未知：#{lock[:error]}")
        return false
      end

      if lock[:locked]
        finish_blocked(log, started, "部署进行中，未执行。持有者：#{lock[:details]}")
        return false
      end

      true
    end

    def finish_blocked(log, started, message)
      broadcast_line(log, message)
      log.finish!(result: "failure", command: "(未执行)", output_digest: message,
                  duration_ms: ((Time.current - started) * 1000).round)
      broadcast_result(log)
    end

    # The page's status bar (#action-result) re-rendered in its final state, in the initiator's
    # language: the broadcast goes to everyone watching, but the initiator is who started it.
    def result_html(log)
      I18n.with_locale(log.user.locale.presence || I18n.default_locale) do
        ApplicationController.render(partial: "actions/run_status", locals: { log: })
      end
    end

    def broadcast_result(log)
      Turbo::StreamsChannel.broadcast_replace_to(
        "action_#{log.id}", target: "action-result", html: result_html(log)
      )
    rescue StandardError => e
      Rails.logger.error("[action] 终态广播失败: #{e.class}")
    end

    def broadcast_line(log, line)
      Turbo::StreamsChannel.broadcast_append_to(
        "action_#{log.id}", target: "action-output",
        html: ActionController::Base.helpers.tag.div(line, class: "output-line")
      )
    rescue StandardError => e
      # A delivery failure must not drag down the execution itself (lesson from plan 01 Task 12)
      Rails.logger.error("[action] 广播失败: #{e.class}")
    end
end
