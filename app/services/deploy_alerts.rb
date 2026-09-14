# 两套数据源的矛盾（spec 03 第 5 节）。
#
# 不建告警表、不加后台 job：告警是由 DeployEvent 的几个时间列派生出来的
# 查询，因此"观测到了"这件事一发生，告警自然就不成立了——不需要任何人
# 去点"我知道了"，也不存在"消解任务挂了导致告警永远挂着"。
#
# 两类告警的阈值量级不同，合成同一个会让其中一个必然误报。
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

  # 总览页格子里的徽章文字：两类告警语义不同（"上报了但观测不到" vs
  # "开了头没收尾"），只有其中一类存在时要各自说清楚是哪一种，
  # 都有的时候才用一个更含糊的总称——不能笼统地都叫"上报未验证"，
  # 那对 unfinished 是错的。
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

    # 「被取代即消解」：该应用已经有更新的、被观测到的事件时，说明状况已经翻篇，
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
