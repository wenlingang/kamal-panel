module DeployEvents
  # 从观测推断部署事件（子设计 05）。
  #
  # 只在【全体收敛】时记一条：配置里每一台 host 都有可达且 running 的观测，
  # 且这些观测的 version 一致。滚动部署中途的混合版本不产生事件，一次部署一行。
  #
  # 有机器失联时不算收敛——那台机器可能还跑着旧版，面板并不知道。沉默比编造正确。
  class Inferrer
    RUNNING_STATUSES = %w[running restarting].freeze

    def self.call(managed_app)
      new(managed_app).call
    end

    def initialize(managed_app)
      @managed_app = managed_app
    end

    def call
      version, converged_at = converged_state
      return if version.nil?
      return if version == managed_app.last_converged_version

      # 基线判断提到最前面：第一次收敛（last_converged_version 还是 nil）
      # 注定不产生事件，提前判断能省掉一次注定被这条守卫丢弃的
      # hook_already_reported? 查询。注意别改坏语义——首次收敛仍然要走到
      # 下面的 update_columns，把基线两列写下来，只是不建事件。
      first_convergence = managed_app.last_converged_version.nil?

      # 比较用的是【更新之前】的边界：这条上报是不是在当前这一轮收敛期内到达的。
      record_inferred(version, converged_at) if !first_convergence && !hook_already_reported?(version)

      # 让位不记事件时同样要更新——否则状态记着上一版，下一次真正的变更会拿
      # 一个错误的时间边界去比。
      managed_app.update_columns(last_converged_version: version,
                                 last_converged_at: converged_at,
                                 updated_at: Time.current)
    end

    private
      attr_reader :managed_app

      # => [version, converged_at] 或 [nil, nil]
      def converged_state
        hosts = managed_app.cached_app_hosts
        rows = running_rows(hosts)

        # 每一台配置里的机器都要有可达且 running 的观测
        return [ nil, nil ] unless hosts.all? { |host| rows.any? { |o| o.host == host } }

        versions = rows.map(&:version).uniq
        return [ nil, nil ] unless versions.one?

        [ versions.first, rows.map(&:observed_at).min ]
      end

      # Observation.latest_for 返回的是该应用曾采集过的【全部】host，包括
      # 已经从 deploy.yml 移除、不再属于配置真相的机器——这类观测是故意
      # 保留的（ManagedAppStatus 只把它们标成 configured: false，
      # PruneObservationsJob 永远保留每个 (app, host) 的最新一行）。如果不
      # 按 cached_app_hosts（配置真相）过滤，一台下线机器留下的"running
      # 旧版本"那行会让 versions.one? 永久为 false，该应用从此再也产不出
      # 推断事件、且没有任何提示；converged_at 取 min 时还会被那行陈旧
      # 时间戳拉低。deploy.yml 是唯一真相，收敛只看配置里还在的这些 host。
      def running_rows(hosts)
        Observation.latest_for(managed_app).select do |o|
          hosts.include?(o.host) &&
            o.reachable? && RUNNING_STATUSES.include?(o.docker_status) && o.version.present?
        end
      end

      def hook_already_reported?(version)
        boundary = managed_app.last_converged_at
        return false if boundary.nil?

        managed_app.deploy_events
                   .where(version: version)
                   .where(created_at: boundary..)
                   .exists?
      end

      def record_inferred(version, converged_at)
        managed_app.deploy_events.create!(
          version: version, source: "inferred",
          # hook 上报路径（Ingest）会写 destination，这条推断路径也要写，
          # 保持两条写入路径对同一张表的字段一致，否则将来按 destination
          # 过滤历史会让推断行整批漏掉。
          destination: managed_app.destination,
          # 推断不出何时开始；performer / command 机器上看不出来，
          # 留空比编一个 "unknown" 诚实。
          started_at: nil, performer: nil, command: nil,
          succeeded_at: converged_at, observed_at: converged_at
        )
      end
  end
end
