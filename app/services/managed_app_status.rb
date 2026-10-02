# Compute the app status from the most recent round of Observations.
class ManagedAppStatus
  LEVELS = %i[drift unhealthy unreachable ok unknown].freeze

  def self.label_for(level) = I18n.t("statuses.#{level}")

  RUNNING_STATUSES = %w[running restarting].freeze

  # The threshold is not hard-coded: it must follow the polling cadence, otherwise on a high-latency
  # link it would cry wolf on a healthy cluster.
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
    return :unreachable if unreachable? || stale?

    :ok
  end

  def label
    self.class.label_for(level)
  end

  def drift?
    versions.size > 1
  end

  # Only look at running containers: stopped older versions are rollback candidates, not drift.
  def versions
    observations.group_by(&:host).flat_map do |_host, host_observations|
      running = host_observations.select { |o| RUNNING_STATUSES.include?(o.docker_status) }
      (running.presence || host_observations).filter_map(&:version)
    end.uniq
  end

  def observed_at
    return nil if any_configured_host_unobserved?

    configured_host_observed_ats.min
  end

  def any_configured_host_unobserved?
    missing_configured_hosts.any?
  end

  # Per-machine detail rows.
  def host_rows
    observed_hosts = observations.map(&:host)
    missing_hosts  = managed_app.cached_app_hosts - observed_hosts

    observed_rows + missing_hosts.map { |host| unobserved_row(host) }
  end

  # An unreachable host falls back to its most recent "reachable" observation.
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
          unparseable_output: observation.error.to_s.include?(
            Collectors::ContainerCollector::UNPARSEABLE_OUTPUT_MARKER
          ),
          routed: routed_status(observation.host, observation.container_name),
          observed_at: observation.observed_at,
          configured: managed_app.cached_app_hosts.include?(observation.host)
        }
      end
    end

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

    def unhealthy?
      observations.any? { |o| o.health == "unhealthy" } || any_reachable_host_without_running_container?
    end

    def any_reachable_host_without_running_container?
      observations.group_by(&:host).any? do |_host, host_observations|
        next false unless host_observations.any?(&:reachable)

        host_observations.none? { |o| RUNNING_STATUSES.include?(o.docker_status) }
      end
    end

    def unreachable?
      observations.any? { |o| !o.reachable } || missing_configured_hosts.any?
    end

    def missing_configured_hosts
      managed_app.cached_app_hosts - observations.map(&:host)
    end

    # machines removed from deploy.yml (even if they still have a record in #observations).
    def configured_host_observed_ats
      managed_app.cached_app_hosts.filter_map { |host| observed_at_for(host) }
    end

    def observed_at_for(host)
      observations.find { |o| o.host == host }&.observed_at
    end

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
