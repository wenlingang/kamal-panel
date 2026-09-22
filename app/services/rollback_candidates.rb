# 面板相对 CLI 的真实增量（spec 7.1）。
class RollbackCandidates
  RUNNING_STATUSES = %w[running restarting].freeze

  def initialize(managed_app)
    @managed_app = managed_app
  end

  def list
    stopped_versions.map do |version|
      missing = hosts_missing(version)

      { version: version,
        available: missing.empty?,
        reason: missing.empty? ? nil : I18n.t("rollback_candidates.cleaned_up",
                                               hosts: missing.join(I18n.t("common.list_separator"))) }
    end
  end

  # 正在跑的那个版本。
  def running_version
    versions = running_versions
    versions.first if versions.one?
  end

  private
    attr_reader :managed_app

    def observations = @observations ||= Observation.latest_for(managed_app).to_a

    def running_versions
      observations.select { |o| RUNNING_STATUSES.include?(o.docker_status) }
                  .filter_map(&:version).uniq
    end

    def stopped_versions
      observations.filter_map(&:version).uniq - running_versions
    end

    def hosts_missing(version)
      managed_app.cached_app_hosts.reject do |host|
        observations.any? { |o| o.host == host && o.version == version }
      end
    end
end
