# The Monday message: last week across every active app (deploys, alerts, backups) and what still
# needs attention, sent to the notification channels that opted in. Plain lines, so every channel
# kind (email, Slack, Feishu, webhook) shows it as is.
class WeeklySummary
  def initialize(now: Time.current)
    @now = now
    @since = now - 7.days
  end

  # [headline, lines]
  def build
    apps = ManagedApp.active.order(:name).to_a
    deploys = DeployEvent.where(managed_app: apps, started_at: since..)
    failed_deploys = deploys.where.not(failed_at: nil).count
    alerts = AlertEvent.where(managed_app: apps).where(fired_at: since..)
    backups = BackupRun.where(managed_app: apps, finished_at: since..)
    attention = attention_items

    lines = [
      I18n.t("weekly_summary.deploys", count: deploys.count, failed: failed_deploys),
      I18n.t("weekly_summary.alerts", count: alerts.count, open: AlertEvent.firing.where(managed_app: apps).count),
      (I18n.t("weekly_summary.backups", count: backups.succeeded.count, failed: backups.failed.count) if BackupPlan.exists?),
      *busiest(apps, deploys, alerts)
    ].compact

    lines << (attention.empty? ? I18n.t("weekly_summary.nothing_pending") : I18n.t("weekly_summary.pending", count: attention.size))
    lines.concat(attention.first(5).map { |item| "· #{item.message}" })

    [ headline(failed_deploys, alerts.count, attention), lines ]
  end

  def message
    headline, lines = I18n.with_locale(I18n.default_locale) { build }
    Notifiers::Message.summary(headline, lines)
  end

  private
    attr_reader :now, :since

    # Seen through an admin's eyes: the summary goes to channels, not to one person.
    def attention_items
      admin = User.where(role: "admin", deactivated_at: nil).first
      admin ? AttentionItems.new(admin, now:).items.reject { |item| item.severity == :notice } : []
    end

    # The apps that changed most, so the message says where the week happened.
    def busiest(apps, deploys, alerts)
      by_app = deploys.group(:managed_app_id).count
      alerted = alerts.group(:managed_app_id).count
      apps.select { |app| by_app[app.id] || alerted[app.id] }
          .sort_by { |app| -(by_app[app.id].to_i + alerted[app.id].to_i) }.first(5)
          .map { |app| I18n.t("weekly_summary.app_line", app: app.name, deploys: by_app[app.id].to_i, alerts: alerted[app.id].to_i) }
    end

    def headline(failed_deploys, alert_count, attention)
      if attention.any? then I18n.t("weekly_summary.headline_attention", count: attention.size)
      elsif failed_deploys.zero? && alert_count.zero? then I18n.t("weekly_summary.headline_quiet")
      else I18n.t("weekly_summary.headline_ok")
      end
    end
end
