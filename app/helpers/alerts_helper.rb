module AlertsHelper
  # Colour tier and icon per event state: firing reads as a problem, pending as "watching",
  # resolved as fine.
  ALERT_STATE_BADGES = {
    "firing" => [ "unhealthy", "unhealthy" ],
    "pending" => [ "drift", "stale" ],
    "resolved" => [ "ok", "ok" ]
  }.freeze

  def alert_state_badge(event)
    level, icon_key = ALERT_STATE_BADGES.fetch(event.state)
    status_badge(level, t("alerts.states.#{event.state}"), icon_key:)
  end

  # The sidebar badge and the overview strip: one cheap COUNT per request.
  def firing_alert_count
    @firing_alert_count ||= AlertEvent.firing.count
  end

  def alert_scope_label(rule)
    rule.managed_app&.name || t("alert_rules.all_apps")
  end

  # One line saying what the rule waits for, next to its condition.
  def alert_rule_summary(rule)
    if rule.log_keyword?
      t("alert_rules.summary.log_keyword", keyword: rule.keyword, window: rule.window_minutes,
                                           threshold: rule.threshold, source: rule.log_source)
    elsif rule.event_condition?
      t("alert_rules.summary.per_event")
    elsif rule.metric_condition?
      t("alert_rules.summary.#{rule.for_minutes.zero? ? 'metric_immediately' : 'metric'}",
        threshold: rule.metric_threshold, count: rule.for_minutes)
    elsif rule.for_minutes.zero?
      t("alert_rules.summary.immediately")
    else
      t("alert_rules.summary.for_minutes", count: rule.for_minutes)
    end
  end

  # Where to look next: a log rule opens the logs page on its keyword (widest window that still
  # covers the rule's), anything else opens the app.
  def alert_event_links(event)
    app = event.managed_app
    links = [ link_to(t("alerts.links.app"), managed_app_path(app), class: "btn-quiet") ]
    rule = event.alert_rule
    if rule.log_keyword? && policy_for(app).view_logs?
      window = LogQuery::WINDOWS.find { |_key, span| span >= rule.window }&.first || LogQuery::DEFAULT_WINDOW
      links << link_to(t("alerts.links.logs"), logs_path(app: app.id, source: rule.log_source, q: rule.keyword, since: window),
                       class: "btn-quiet")
    end
    safe_join(links)
  end

  def alert_event_duration(event)
    distance_of_time_in_words(event.duration)
  end
end
