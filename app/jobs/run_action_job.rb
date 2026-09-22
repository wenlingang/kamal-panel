# 执行一个动作。
class RunActionJob < ApplicationJob
  queue_as :default

  def perform(audit_log_id)
    log = AuditLog.find(audit_log_id)
    app = log.managed_app
    action = Actions::Base.find(log.action_name).new(app, target_version: log.target_version)
    started = Time.current

    return if action.class.requires_lock? && !lock_free?(app, log, started)

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
    broadcast_result(log)

    # 不拿命令退出码当结论（spec 8.4）：触发 burst 轮询，用新的 Observation 确认。
    PollCadence.mark_burst!(app)
    PollManagedAppJob.perform_later(app)
  end

  private
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

    def result_text(log)
      I18n.with_locale(log.user.locale.presence || I18n.default_locale) do
        log.result == "success" ? I18n.t("actions.result.succeeded") : I18n.t("actions.result.failed")
      end
    end

    def broadcast_result(log)
      html = ActionController::Base.helpers.tag.strong(result_text(log))
      Turbo::StreamsChannel.broadcast_replace_to(
        "action_#{log.id}", target: "action-result", html: html
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
      # 投递失败不得连累执行本身（计划 01 Task 12 的教训）
      Rails.logger.error("[action] 广播失败: #{e.class}")
    end
end
