# One collection round for one app.
class PollManagedAppJob < ApplicationJob
  queue_as :default

  def perform(managed_app)
    # accumulate one failure observation — just give up.
    return if managed_app.deactivated?

    error = nil
    parse_error = nil

    begin
      Collectors::ContainerCollector.call(managed_app)
    rescue Kamal::ConfigParser::ParseError => e
      parse_error = e
    rescue StandardError => e
      error = e
    end

    begin
      # Parse failed — the two failures most likely share a source, and running the second one would
      # only waste a subprocess.
      Collectors::ProxyCollector.call(managed_app) unless parse_error
    rescue Kamal::ConfigParser::ParseError => e
      parse_error ||= e
    rescue StandardError => e
      # Both blew up: we can only pick one to raise.
      error ||= e
    end

    begin
      # Backfill goes after collection: what it reads is the observation just written this round.
      # Isolated from the others, like the two collectors — if it raises, it must not drag down the
      # collection results.
      DeployEvents::Reconciler.call(managed_app) unless parse_error
    rescue StandardError => e
      error ||= e
    end

    begin
      # sees "this version was just backfilled" and so yields, not recording a duplicate inferred
      # event.
      DeployEvents::Inferrer.call(managed_app) unless parse_error
    rescue StandardError => e
      error ||= e
    end

    if parse_error
      record_poll_error(managed_app, parse_error)
      Rails.logger.warn("[poll] #{managed_app.name} 的 deploy.yml 无法解析：#{parse_error.message}")
    else
      clear_poll_error(managed_app)
    end

    broadcast_overview_refresh
    broadcast_host_status_refresh(managed_app) unless parse_error

    raise error if error
  end

  private
    def clear_poll_error(managed_app)
      return if managed_app.last_poll_error.nil?

      managed_app.update_columns(last_poll_error: nil, last_poll_error_at: nil, first_poll_error_at: nil)
    end

    def record_poll_error(managed_app, error)
      attrs = { last_poll_error: error.message.to_s.truncate(2000), last_poll_error_at: Time.current }
      # overwriting on every round would make an app that has been broken for days forever show
      # "less than a minute ago".
      attrs[:first_poll_error_at] = Time.current if managed_app.first_poll_error_at.nil?

      managed_app.update_columns(**attrs)
    end

    # The overview page subscribes to "overview"; notified once per collection round.
    def broadcast_overview_refresh
      deliver_overview_refresh
    end

    # The detail page subscribes to "managed_app_<id>"; #host-status is replaced as a whole after
    # each collection round.
    def broadcast_host_status_refresh(managed_app)
      managed_app.reload
      status = ManagedAppStatus.new(managed_app)

      html = ApplicationController.render(
        partial: "managed_apps/host_status",
        locals: { managed_app: managed_app, status: status }
      )

      deliver_host_status_refresh(managed_app, html)
    end

    def deliver_host_status_refresh(managed_app, html)
      Turbo::StreamsChannel.broadcast_stream_to(
        "managed_app_#{managed_app.id}",
        content: Turbo::StreamsChannel.turbo_stream_action_tag(:replace, target: "host-status", template: html)
      )
    rescue StandardError => e
      Rails.logger.error("[poll] 详情页广播投递失败：#{e.class}: #{e.message}")
    end

    def deliver_overview_refresh
      Turbo::StreamsChannel.broadcast_refresh_to("overview")
    rescue StandardError => e
      Rails.logger.error("[poll] 总览页广播投递失败：#{e.class}: #{e.message}")
    end
end
