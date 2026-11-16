# The overview's "needs attention" list: things that are wrong or about to go wrong and won't fix
# themselves, gathered from what the panel already knows (no remote calls). Each item says what,
# since when, and where to go. Someone can dismiss an item; it comes back if the same problem
# starts again later (DismissedIssue is keyed by the item and its start).
#
# Alerts that are firing are not repeated here: the overview and the alerts page already show them.
# This is for the quieter problems no rule covers, or that nobody set a rule for.
class AttentionItems
  SEVERITIES = %i[critical warning notice].freeze
  CERT_WARN_DAYS = 21
  CERT_CRITICAL_DAYS = 7

  # key: stable id of the problem; since: when it started (ISO 8601), part of the dismissal key.
  Item = Data.define(:key, :severity, :message_key, :args, :since, :path) do
    def message = I18n.t("attention.items.#{message_key}", **args)
    def since_time = Time.zone.parse(since.to_s)
  end

  def initialize(user, now: Time.current)
    @user = user
    @now = now
  end

  # Not yet dismissed, worst first, then oldest first.
  def items
    @items ||= begin
      dismissed = DismissedIssue.pluck(:issue_key, :since).to_set
      all.reject { |item| dismissed.include?([ item.key, item.since ]) }
         .sort_by { |item| [ SEVERITIES.index(item.severity), item.since.to_s ] }
    end
  end

  def find(key) = all.find { |item| item.key == key }

  def all
    @all ||= (app_items + backup_items + certificate_items + settings_items).compact
  end

  private
    attr_reader :user, :now

    def routes = Rails.application.routes.url_helpers

    def apps
      @apps ||= ManagedApp.active.order(:name).select { |app| ManagedAppPolicy.new(user, app).act? || user.ops? }
    end

    def item(key, severity, message_key, since, path, **args)
      Item.new(key:, severity:, message_key:, args:, since: since&.utc&.iso8601 || "-", path:)
    end

    def app_items
      apps.flat_map do |app|
        [
          (item("config_broken:#{app.id}", :critical, "config_broken", app.first_poll_error_at,
                routes.managed_app_path(app), app: app.name) if app.last_poll_error.present?),
          (item("no_ssh_key:#{app.id}", :warning, "no_ssh_key", app.created_at,
                routes.edit_managed_app_path(app), app: app.name) if app.ssh_credential_id.nil?)
        ]
      end
    end

    def backup_items
      BackupPlan.enabled.where(managed_app: apps).includes(:managed_app).flat_map do |plan|
        last = plan.backup_runs.where.not(state: "running").order(started_at: :desc).first
        path = routes.managed_app_path(plan.managed_app, tab: "backups")
        last_success = plan.backup_runs.succeeded.maximum(:finished_at)
        expected_by = (last_success || plan.created_at) + (plan.every_hours * 2).hours

        if last&.failed?
          [ item("backup_failed:#{plan.id}", :critical, "backup_failed", first_failure_since(plan, last_success), path,
                 app: plan.managed_app.name, accessory: plan.accessory) ]
        elsif expected_by < now
          [ item("backup_overdue:#{plan.id}", :warning, "backup_overdue", expected_by, path,
                 app: plan.managed_app.name, accessory: plan.accessory) ]
        else
          []
        end
      end
    end

    # The start of the current run of failures: the first failure after the last success.
    def first_failure_since(plan, last_success)
      scope = plan.backup_runs.failed
      scope = scope.where("finished_at > ?", last_success) if last_success
      scope.minimum(:finished_at)
    end

    def certificate_items
      hosts = apps.select { |app| app.last_poll_error.blank? }.flat_map do |app|
        app.parsed_config.domains.select { |domain| domain[:ssl] }.map { |domain| [ domain[:host], app ] }
      rescue Kamal::ConfigParser::ParseError
        []
      end.to_h

      CertificateCheck.where(host: hosts.keys).where(not_after: ..(now + CERT_WARN_DAYS.days)).map do |check|
        days = [ check.days_left(now), 0 ].max
        item("cert:#{check.host}", days <= CERT_CRITICAL_DAYS ? :critical : :warning, "cert_expiring",
             check.not_after - CERT_WARN_DAYS.days, routes.managed_app_path(hosts[check.host]),
             host: check.host, days:)
      end
    end

    # Things only an admin can fix: storage that stopped working, channels that stopped delivering,
    # and alerting that can't reach anyone.
    def settings_items
      return [] unless user.admin?

      destinations = BackupDestination.where.not(last_check_error: nil).map do |destination|
        item("backup_destination:#{destination.id}", :warning, "backup_destination_failing", destination.last_checked_at,
             routes.backup_destinations_path, name: destination.name)
      end

      channels = NotificationChannel.enabled.where.not(last_error_at: nil).select do |channel|
        channel.last_delivered_at.nil? || channel.last_error_at > channel.last_delivered_at
      end.map do |channel|
        item("channel:#{channel.id}", :warning, "channel_failing", channel.last_error_at,
             routes.notification_channels_path, name: channel.name)
      end

      setup = []
      if ManagedApp.active.exists? && !AlertRule.enabled.exists?
        setup << item("no_alert_rules", :notice, "no_alert_rules", nil, routes.new_alert_rule_path)
      elsif AlertRule.enabled.exists? && !NotificationChannel.enabled.exists?
        setup << item("no_channels", :notice, "no_channels", nil, routes.new_notification_channel_path)
      end
      if (version = PanelUpdates.available)
        setup << item("panel_update:#{version}", :notice, "panel_update", nil, PanelUpdates.release_url(version), version:)
      end

      destinations + channels + setup
    end
end
