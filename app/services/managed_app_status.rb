# 由最近一轮 Observation 计算应用状态。
#
# 优先级（spec 8.2）：
#   drift > unhealthy > unreachable > ok
#
# 版本漂移排最前，因为它意味着「部署没做完」——比单个容器异常更需要
# 立刻处理，且在 CLI 下极难发现。
class ManagedAppStatus
  # 只留【键】。显示名是 i18n 的事，而且不能在这里求值——常量在类加载时
  # 就定型了，那时 I18n.locale 还是启动时的默认值，此后任何一次语言切换都
  # 不会反映到它上面（设计 13 §10）。
  LEVELS = %i[drift unhealthy unreachable ok unknown].freeze

  def self.label_for(level) = I18n.t("statuses.#{level}")

  RUNNING_STATUSES = %w[running restarting].freeze

  # 阈值不硬编码：它必须随轮询节奏走，否则在高延迟链路上会对健康集群狼来了。
  # 见 spec 10.4——capture_many 是串行的，50 台经跳板机时单轮可达数十秒。
  # 三倍空闲间隔意味着「连续错过三轮」才判定陈旧，与原先 3 分钟对 60 秒节奏的比例一致。
  STALE_MULTIPLIER = 3

  def self.stale_threshold
    PollCadence::IDLE * STALE_MULTIPLIER
  end

  def initialize(managed_app)
    @managed_app = managed_app
  end

  def level
    return :unknown     if observations.empty?
    return :drift       if drift?
    return :unhealthy   if unhealthy?
    # 数据过期与「机器失联」共享同一个黄色档位，而不是被 stale? 单独降级成
    # 一个新的第六态：两者说的是同一件事——「面板此刻不能替这台/这批机器背书」，
    # 只是原因不同（连不上 vs. 采集根本没跑）。把它们合并成一档，既满足
    # 「不新增第六态」的约束，也避免过期数据顶着绿色「正常」徽章招摇过市
    # （见 final review C1：spec 8.2 的三秒扫视必须能看到这个信号）。
    return :unreachable if unreachable? || stale?

    :ok
  end

  def label
    self.class.label_for(level)
  end

  def drift?
    versions.size > 1
  end

  # 只看正在运行的容器：已停止的旧版本是回滚候选，不是漂移。
  # 但这是"每台机器各自"判断的——如果某台机器上压根没有正在运行的容器
  # （比如新版本部署后直接崩溃退出），那台机器就没有"当前版本"可言，
  # 只能退而使用它仅有的（已停止的）记录，否则这台机器的异常会被
  # 完全掩盖掉。
  def versions
    observations.group_by(&:host).flat_map do |_host, host_observations|
      running = host_observations.select { |o| RUNNING_STATUSES.include?(o.docker_status) }
      (running.presence || host_observations).filter_map(&:version)
    end.uniq
  end

  # 故意不用 Observation.last_observed_at_for 重新查一次：那样会绕过
  # #observations 的内存缓存，在轮询中可能返回一个比屏幕上这批数据更新的
  # 时间戳——总览页整体的可信度就建立在"数据年龄"这行字上，它必须来自
  # 正在展示的这批观测，而不是"此刻数据库里最新一次采集是什么时候"。
  #
  # 算的是"当下配置里的每一台机器，各自最近一次被采集到的时间"里最旧的
  # 那个——不是"#observations 这批记录里最旧的那条"，两者是两回事，
  # 差之毫厘、方向截然相反：
  #
  #   低估的方向：一台配置了但从没被采集过的机器，在 #observations 里
  #   压根没有一条记录。如果只看 #observations 本身的 min，这台机器对
  #   "数据年龄"完全隐形——它其实是最旧的（没有任何数据），却被当成
  #   "不存在"，于是指示器可能显示"刚采集过"，而实际上有一台机器面板
  #   压根没看过它。
  #
  #   高估的方向：一台已经从 deploy.yml 里移除、但历史上被采集过的机器，
  #   它在 #observations 里的那条记录不会因为配置改了就消失（Observation
  #   只追加、从不修改），如果不按"当下配置里有哪些机器"过滤，它会永远
  #   拖着一个旧时间戳，把整个应用钉死在"已过期"——这是一种"狼来了"式的
  #   回归：指示器永远红，操作者会学会不再看它，这正是这个指示器存在的
  #   意义要防止的反面。
  #
  # 所以这里显式地只看"当下配置里的机器"（#any_configured_host_unobserved?
  # 处理"有配置的机器一条观测都没有"这种没有下限可言的情况——那种情况下
  # 不给出一个看似精确、实则不成立的数字，见 #stale? 和视图）。
  def observed_at
    return nil if any_configured_host_unobserved?

    configured_host_observed_ats.min
  end

  # 配置里存在但一条观测都没有的机器——不是"缺失值可以忽略"，是"没有下限
  # 可言的最旧"：数字年龄在这种情况下没有意义，宁可让调用方（视图）说清楚
  # "有主机没采集过"，也不要吐出一个看起来精确、实则不成立的数字。
  def any_configured_host_unobserved?
    missing_configured_hosts.any?
  end

  # 逐机器的明细行。跟总览页的单一 :unreachable 严重度不同（那个只需要
  # 一个"我信不过这个应用"的信号），这里必须能区分"问过、没答上"
  # （reachable: false）和"配置里有这台机器，但从没问过它"（reachable:
  # nil）——总览页那个单一 badge 把两者揉成一个"机器失联"是对的（严重度
  # 一样），但这里如果对着一台从没采集过的机器说"失联"，就是在说一句
  # 小谎："失联"暗示了"曾经联系上、现在断了"，而这台机器面板压根没试过。
  def host_rows
    observed_hosts = observations.map(&:host)
    missing_hosts  = managed_app.cached_app_hosts - observed_hosts

    observed_rows + missing_hosts.map { |host| unobserved_row(host) }
  end

  # 失联的主机回落到它最近一次「可达」的观测。
  #
  # 绝不清空界面（spec 6.4）：让人能区分「服务挂了」与「面板瞎了」。
  def last_known_rows
    host_rows.map do |row|
      next row if row[:reachable]

      fallback = last_reachable_observation(row[:host])
      next row if fallback.nil?

      row.merge(
        version: fallback.version,
        docker_status: fallback.docker_status,
        health: fallback.health,
        stale_since: fallback.observed_at
      )
    end
  end

  def stale?(threshold: self.class.stale_threshold)
    any_configured_host_unobserved? || observed_at.nil? || observed_at < threshold.ago
  end

  private
    attr_reader :managed_app

    def observed_rows
      observations.map do |observation|
        {
          host: observation.host,
          role: observation.role,
          version: observation.version,
          docker_status: observation.docker_status,
          health: observation.health,
          reachable: observation.reachable,
          error: observation.error,
          # "docker ps 读不懂"与"机器失联"在逐主机文案上是两回事。判断放在这里
          # 而不是视图里：视图曾经自己 include? 匹配那句中文，等于把同样的五个字
          # 存了两份（见 Collectors::ContainerCollector::UNPARSEABLE_OUTPUT_MARKER）。
          unparseable_output: observation.error.to_s.include?(
            Collectors::ContainerCollector::UNPARSEABLE_OUTPUT_MARKER
          ),
          routed: routed_status(observation.host, observation.container_name),
          observed_at: observation.observed_at,
          # 这台机器曾经被采集过，但当下的 deploy.yml 里已经不再列出它——
          # 可能是被下线了，也可能是配置改过。deploy.yml 是唯一真相
          # （spec 5.1），所以不能让它继续无条件地显示"正常"：那等于面板
          # 在替一台不再属于这个应用的机器背书。这里不把行删掉（删掉等于
          # 悄悄丢弃"它曾经存在过"这条信息），而是留给 host_table 视图去
          # 标注，交给使用者判断。
          configured: managed_app.cached_app_hosts.include?(observation.host)
        }
      end
    end

    # reachable: nil（既不是 true 也不是 false）故意用来标记"从没问过"，
    # 跟 Observation#reachable 的 true/false 区分开——这台机器从来没有一条
    # Observation 记录，谈不上"可达"或"不可达"。
    def unobserved_row(host)
      {
        host: host,
        role: role_for_host(host),
        version: nil,
        docker_status: nil,
        health: nil,
        reachable: nil,
        error: nil,
        routed: nil,
        observed_at: nil,
        configured: true
      }
    end

    def role_for_host(host)
      managed_app.parsed_config.roles
        .select { |role| role[:hosts].include?(host) }
        .map { |role| role[:name] }
        .join("/").presence
    end

    def last_reachable_observation(host)
      Observation
        .where(managed_app: managed_app, host: host, reachable: true)
        .where.not(container_name: nil)
        .order(observed_at: :desc)
        .first
    end

    def observations
      @observations ||= Observation.latest_for(managed_app).to_a
    end

    # 一台可达的机器，如果没有任何正在运行的容器——无论是因为压根没有
    # 匹配到容器（从没在这台机器上部署过，或容器被整个移除了），还是
    # 因为曾经部署过的容器全部退出——都是"这里没有在服务"，这是容器层面
    # 的异常，跟漂移、跟"联系不上机器"是两码事。之前的实现要求
    # container_name.present?，导致"可达但零容器"那一支被漏判成
    # 观察不到任何异常信号，从而落到 :ok——这正是本产品要防止的
    # "没数据看起来像一切正常"，而且恰好发生在最重要的一屏上。
    def unhealthy?
      observations.any? { |o| o.health == "unhealthy" } || any_reachable_host_without_running_container?
    end

    def any_reachable_host_without_running_container?
      observations.group_by(&:host).any? do |_host, host_observations|
        next false unless host_observations.any?(&:reachable)

        host_observations.none? { |o| RUNNING_STATUSES.include?(o.docker_status) }
      end
    end

    # "机器失联"覆盖两种同一类问题："问过、没答上"（SSH 失败，reachable:
    # false）和"配置里有这台机器，但从来没问过它"（deploy.yml 里的主机，
    # 一次都没被 Observation 记录下来——新加的机器、或者数据被清理过）。
    # 两者对操作者而言是同一件事：这台机器的状态无法证实，不能因为
    # "别的机器看起来都挺好"就把整个应用判成正常。
    def unreachable?
      observations.any? { |o| !o.reachable } || missing_configured_hosts.any?
    end

    def missing_configured_hosts
      managed_app.cached_app_hosts - observations.map(&:host)
    end

    # 只看"当下配置里的机器"各自最近一次的观测时间——不包括已经从
    # deploy.yml 移除的机器（哪怕它在 #observations 里还有一条记录）。
    def configured_host_observed_ats
      managed_app.cached_app_hosts.filter_map { |host| observed_at_for(host) }
    end

    def observed_at_for(host)
      observations.find { |o| o.host == host }&.observed_at
    end

    # 「接流量」是三态，不是布尔：`nil` 表示「面板不知道」，跟「否」不是一回事
    # （见 final review I2 / 分诊 21）。以下情形一律返回 nil，而不是 false：
    #   - 这台机器压根没有容器（container_name 为 nil，没有可比对的对象）
    #   - 这台机器从没采集过 proxy 状态
    #   - 该机器最新一条 ProxyTarget 是 unreachable（问不到 kamal-proxy）
    #   - kamal-proxy 返回的内容形状认不出来（raw 有值、service_name 为空）
    # 只有真正拿到一份可信的路由表时，才给出确定的 true/false。
    def routed_status(host, container_name)
      return nil if container_name.nil?

      targets = proxy_targets_by_host[host]
      return nil if targets.blank?
      return nil if targets.any? { |t| t.reachable == false }
      return nil if targets.any? { |t| t.raw.present? && t.service_name.blank? }

      routed_container_names(targets).include?(container_name)
    end

    def routed_container_names(targets)
      targets.flat_map { |t| t.target.to_s.split(", ") }.map { |t| t.split(":").first }
    end

    def proxy_targets_by_host
      @proxy_targets_by_host ||= ProxyTarget.latest_for(managed_app).group_by(&:host)
    end
end
