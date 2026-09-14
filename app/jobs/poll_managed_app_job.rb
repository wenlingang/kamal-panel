# 一个应用的一轮采集。
#
# 单个采集器失败不得让整轮失败——失联本身就是要采集并呈现的信息
# （spec 6.4）。但这仅限于 host 级别的失联，采集器内部已经把它变成了
# 一条 unreachable 记录，不会抛出来。
#
# 这里要接住的是另一种情况：某个采集器自己代码有 bug，抛出了异常。
# 这种异常不该被悄悄吞掉——吞掉代码 bug 会让面板开始撒谎——但也不能
# 让它连累另一个采集器：容器采集器炸了不该导致路由数据也没采到。
# 所以两个采集器各自独立执行，都跑完之后再把（如果有）异常抛出去，
# 让 Solid Queue 按正常的失败任务重试。
class PollManagedAppJob < ApplicationJob
  queue_as :default

  def perform(managed_app)
    # 停用时可能已经有一轮采集躺在队列里。停用会释放凭据绑定，所以继续采只会
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
      # deploy.yml 已经解析不了了，没必要再让路由采集器重复触发一次同样的
      # 解析失败——两次失败多半同源，跑第二次只是浪费一次子进程。
      Collectors::ProxyCollector.call(managed_app) unless parse_error
    rescue Kamal::ConfigParser::ParseError => e
      parse_error ||= e
    rescue StandardError => e
      # 两个都炸了：只能选一个抛出去。选先发生的（容器采集器）那个——
      # 它在数组里天然排在前面，行为可预测；两个异常多半同源
      # （比如都是 deploy.yml 解析失败），保留哪个不影响下面的处理。
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
      # 顺序有讲究：Reconciler 先回填 hook 事件的 observed_at，Inferrer 才能
      # 看见"这一版刚被回填过"，从而让位不记重复的推断事件。
      DeployEvents::Inferrer.call(managed_app) unless parse_error
    rescue StandardError => e
      error ||= e
    end

    # 配置解析结果必须在 broadcast_overview_refresh 之前落库：那一步会
    # 用一份全新读取的 ManagedApp 重新渲染总览网格里的这一行（包括这个
    # 应用自己），如果它还读到旧的 last_poll_error（nil），视图就会再次
    # 尝试调用 cached_app_hosts / parsed_config，在渲染阶段重新炸出同一个
    # ParseError——而这次是从 ApplicationView 内部抛出，不会被下面这个
    # 方法级 rescue 接住（本项修复过程中发现并需要一并堵上的口子，见
    # final review I4）。
    if parse_error
      record_poll_error(managed_app, parse_error)
      # deploy.yml 现在解析不了了（用户改坏了配置）。吞掉异常是对的——这是
      # 用户错误，不是程序缺陷，不该把整个 job 搞崩——但只留一行日志会让这个
      # 应用的轮询永久静默停摆：操作者在 UI 上除了数据越来越旧之外看不到任何
      # "为什么"。把原因落到 ManagedApp 上，供总览页/详情页展示。
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
      # 首次失败的时间戳只写一次——横幅声称「自 X 起每轮都失败」，
      # 每轮覆写会让坏了几天的应用永远显示「不到一分钟前」。
      attrs[:first_poll_error_at] = Time.current if managed_app.first_poll_error_at.nil?

      managed_app.update_columns(**attrs)
    end

    # 总览页订阅 "overview"，每采集一轮通知它一次，操作者不需要手动刷新。
    #
    # 广播的是一条 refresh，不是渲染好的网格。总览页支持按名称/状态筛选
    # （OverviewFilter），而筛选条件只存在于各自浏览器的 URL 里——服务端
    # 无从知道哪个人正在筛什么。此前这里渲染一份全量网格去替换
    # #overview-grid，对正在筛选的人就是错的：他筛出来的三行会被悄悄换回
    # 全部应用，而且他什么也没做。refresh 把"渲染什么"的决定权交回给
    # 浏览器——每个人带着自己当前的 URL 回来重新请求这一页，页面用 morph
    # 合并（布局里的 turbo-refresh-method），滚动位置与输入框焦点都保住，
    # 搜索框正在打字时被刷新不会丢字。
    #
    # 代价是每轮采集从"服务端渲一次、广播一条"变成"每个在看总览的浏览器
    # 各自回来请求一次"。这个面板的并发量（内部运维面板，同时看总览的人
    # 个位数）担得起。
    #
    # 投递仍然单独一层并吞掉异常：Solid Cable 抖动、序列化失败这类传输层
    # 问题是一次性的、自我修复的退化——下一轮采集会再广播一次，页面最多
    # 落后一个轮询周期，不值得让已经成功持久化的采集结果被判定为失败重来
    # 一遍（见类注释）。
    def broadcast_overview_refresh
      deliver_overview_refresh
    end

    # 详情页订阅 "managed_app_<id>"，每轮采集后整块替换 #host-status。
    # 配置解析失败时不广播：那种情况下详情页走的是"退化成只读原始观测"的
    # 另一条分支，#host-status 根本不存在，替换一个不存在的目标只会静默丢弃。
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
