module DeployEvents
  # 从观测推断部署事件（子设计 05）。
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
      first_convergence = managed_app.last_converged_version.nil?

      # 比较用的是【更新之前】的边界：这条上报是不是在当前这一轮收敛期内到达的。
      record_inferred(version, converged_at) if !first_convergence && !hook_already_reported?(version)

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

        return [ nil, nil ] unless hosts.all? { |host| rows.any? { |o| o.host == host } }

        versions = rows.map(&:version).uniq
        return [ nil, nil ] unless versions.one?

        [ versions.first, rows.map(&:observed_at).min ]
      end

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
          destination: managed_app.destination,
          # 推断不出何时开始；
          # 留空比编一个 "unknown" 诚实。
          started_at: nil, performer: nil, command: nil,
          succeeded_at: converged_at, observed_at: converged_at
        )
      end
  end
end
