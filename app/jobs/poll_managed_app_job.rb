# 一个应用的一轮采集。
class PollManagedAppJob < ApplicationJob
  queue_as :default

  def perform(managed_app)
    # 攒一条失败观测——直接放弃。
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
      # 解析失败——两次失败多半同源，跑第二次只是浪费一次子进程。
      Collectors::ProxyCollector.call(managed_app) unless parse_error
    rescue Kamal::ConfigParser::ParseError => e
      parse_error ||= e
    rescue StandardError => e
      # 两个都炸了：只能选一个抛出去。
      error ||= e
    end

    begin
      # 回填放在采集之后：它读的就是这一轮刚写下的观测。
      # 与两个采集器一样彼此隔离——它自己抛异常不能连累采集结果。
      DeployEvents::Reconciler.call(managed_app) unless parse_error
    rescue StandardError => e
      error ||= e
    end

    begin
      # 看见"这一版刚被回填过"，从而让位不记重复的推断事件。
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
      # 每轮覆写会让坏了几天的应用永远显示「不到一分钟前」。
      attrs[:first_poll_error_at] = Time.current if managed_app.first_poll_error_at.nil?

      managed_app.update_columns(**attrs)
    end

    # 总览页订阅 "overview"，每轮采集通知一次。
    def broadcast_overview_refresh
      deliver_overview_refresh
    end

    # 详情页订阅 "managed_app_<id>"，每轮采集后整块替换 #host-status。
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
