# 两套数据源的矛盾（spec 03 第 5 节）。
class DeployAlerts
  # 告警是「现在需要有人看一眼」的东西：三天前的矛盾属于历史，历史区自己会显示。
  # 只看最近这个窗口内（按 created_at）的事件，避免早已不成立的旧矛盾永久占着告警位。
  RECENT_WINDOW = 24.hours

  def initialize(managed_app)
    @managed_app = managed_app
  end

  def list
    unobserved + unfinished
  end

  def any? = list.any?

  def badge_text
    kinds = list.map { |alert| alert[:kind] }.uniq
    return nil if kinds.empty?

    if kinds == [ :unobserved ]
      I18n.t("deploy_alerts.unobserved")
    elsif kinds == [ :unfinished ]
      I18n.t("deploy_alerts.unfinished")
    else
      I18n.t("deploy_alerts.mixed")
    end
  end

  private
    attr_reader :managed_app

    def unobserved
      not_superseded(
        managed_app.deploy_events
                   .where(observed_at: nil)
                   .where.not(succeeded_at: nil)
                   .where(succeeded_at: ..DeployEvent::UNOBSERVED_AFTER.ago)
                   .where(created_at: RECENT_WINDOW.ago..)
      ).recent_first.map do |event|
        { kind: :unobserved, event: event,
          message: I18n.t("deploy_alerts.unobserved_message",
                           version: event.version, ago: ago(event.succeeded_at)) }
      end
    end

    def unfinished
      not_superseded(
        managed_app.deploy_events
                   .where(succeeded_at: nil)
                   .where.not(started_at: nil)
                   .where(started_at: ..DeployEvent::UNFINISHED_AFTER.ago)
                   .where(created_at: RECENT_WINDOW.ago..)
      ).recent_first.map do |event|
        { kind: :unfinished, event: event,
          message: I18n.t("deploy_alerts.unfinished_message",
                           version: event.version,
                           started_at: event.started_at.strftime("%H:%M")) }
      end
    end

    # 旧的矛盾不再需要有人看——历史区仍然留着这行事件本身作为痕迹。
    def not_superseded(scope)
      cutoff = managed_app.deploy_events.where.not(observed_at: nil).maximum(:created_at)
      return scope unless cutoff

      scope.where(created_at: cutoff..)
    end

    def ago(time)
      I18n.t("deploy_alerts.ago", time: ApplicationController.helpers.time_ago_in_words(time))
    end
end
