# 执行一个动作。顺序是刻意的（spec 7.5）：
#   审计先落 pending → 检查锁 → 执行 → 更新审计
# 面板中途崩溃时留下的 pending 记录，正是「有人发起过这个操作」的证据。
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
      # 被锁挡住的动作同样要把"执行中……"换掉，否则这一页会永远停在执行中
      broadcast_result(log)
    end

    # 后台任务里没有请求上下文，也就没有"当前用户"——但这条广播是给人看的，
    # 总得挑一种语言。挑【发起这次动作的人】：这一页基本上就是他在盯着。
    # 代价说清楚：如果另一个语言不同的人也开着同一页，他会看到发起人的语言，
    # 直到刷新（刷新后由 actions/show 自己按他的 locale 渲染）。
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
