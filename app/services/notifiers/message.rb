module Notifiers
  # What one notification says, built once and handed to every channel of the rule. Rendered in the
  # default locale: a notification has many readers and no "current user" to take a language from.
  #
  # kind: "firing" (just started), "reminder" (still firing, see AlertEvent::RENOTIFY_AFTER),
  # "resolved", or "test" (the settings page's "send test" button).
  Message = Data.define(:kind, :state, :rule_id, :rule_name, :condition, :app_id, :app_name, :text,
                        :started_at, :fired_at, :resolved_at, :url) do
    def self.for_event(event, kind)
      I18n.with_locale(I18n.default_locale) do
        new(kind:, state: event.state, rule_id: event.alert_rule_id, rule_name: event.alert_rule.name,
            condition: event.alert_rule.condition, app_id: event.managed_app_id,
            app_name: event.managed_app.name, text: event.message,
            started_at: event.started_at, fired_at: event.fired_at, resolved_at: event.resolved_at,
            url: PanelUrl.for(Rails.application.routes.url_helpers.managed_app_path(event.managed_app_id)))
      end
    end

    def self.test(channel)
      I18n.with_locale(I18n.default_locale) do
        new(kind: "test", state: "test", rule_id: nil, rule_name: I18n.t("notifiers.test_rule"),
            condition: nil, app_id: nil, app_name: nil,
            text: I18n.t("notifiers.test_text", channel: channel.name),
            started_at: Time.current, fired_at: nil, resolved_at: nil,
            url: PanelUrl.for(Rails.application.routes.url_helpers.alerts_path))
      end
    end

    def test? = kind == "test"

    # "[告警] 应用不健康 · demo-api"
    def title
      I18n.with_locale(I18n.default_locale) do
        prefix = I18n.t("notifiers.prefix.#{kind}")
        [ "[#{prefix}] #{rule_name}", app_name ].compact.join(" · ")
      end
    end

    # The plain-text body every channel can show: the message, the times, the link.
    def lines
      I18n.with_locale(I18n.default_locale) do
        [
          text,
          (I18n.t("notifiers.started_at", time: format_time(started_at)) if started_at && !test?),
          (I18n.t("notifiers.resolved_at", time: format_time(resolved_at)) if resolved_at),
          url
        ].compact
      end
    end

    def body = lines.join("\n")

    # The webhook's JSON body: stable field names, ISO 8601 times, for whatever is on the other end.
    def as_payload
      {
        event: test? ? "test" : "alert.#{kind}",
        state:,
        rule: rule_id && { id: rule_id, name: rule_name, condition: },
        app: app_id && { id: app_id, name: app_name },
        title:,
        message: text,
        started_at: started_at&.iso8601,
        fired_at: fired_at&.iso8601,
        resolved_at: resolved_at&.iso8601,
        url:
      }
    end

    private
      def format_time(time) = time.in_time_zone.strftime("%Y-%m-%d %H:%M:%S %Z")
  end
end
