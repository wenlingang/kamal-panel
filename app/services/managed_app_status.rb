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

  # The level of one collection round judged on its own rows alone: no config, no clock. The
  # heartbeat strip (StatusHistory) uses it for past rounds, where "is this stale now" and "which
  # hosts does today's deploy.yml list" are not questions that round can answer. #level layers
  # exactly those two checks on top, so the rules for drift / unhealthy / unreachable live once.
  def self.round_level(observations)
    return :unknown     if observations.empty?
    return :drift       if versions_of(observations).size > 1
    return :unhealthy   if unhealthy_rows?(observations)
    return :unreachable if observations.any? { |o| !o.reachable }

    :ok
  end

  # Only look at running containers: stopped older versions are rollback candidates, not drift.
  def self.versions_of(observations)
    observations.group_by(&:host).flat_map do |_host, host_observations|
      running = host_observations.select { |o| RUNNING_STATUSES.include?(o.docker_status) }
      (running.presence || host_observations).filter_map(&:version)
    end.uniq
  end

  # An unhealthy container, or a host that answered but runs none of this app's containers.
  def self.unhealthy_rows?(observations)
    return true if observations.any? { |o| o.health == "unhealthy" }

    observations.group_by(&:host).any? do |_host, host_observations|
      next false unless host_observations.any?(&:reachable)

      host_observations.none? { |o| RUNNING_STATUSES.include?(o.docker_status) }
    end
  end

  def initialize(managed_app)
    @managed_app = managed_app
  end

  def level
    round = self.class.round_level(observations)
    return round if round != :ok && round != :unreachable
    return :unreachable if unreachable? || stale?

    :ok
  end

  def label
    case badge_key
    when "stale", "unparseable" then I18n.t("statuses.#{badge_key}")
    else self.class.label_for(level)
    end
  end

  # Stale data shares the unreachable tier (same colour, sort and filter), but saying "host
  # unreachable" when every host answered last time is simply wrong. Only the wording and icon differ.
  def stale_only?
    level == :unreachable && !unreachable?
  end

  # Which icon/label variant to show; the CSS tier stays `level`. Within the unreachable tier the
  # wording follows the actual cause: stale data, or hosts that answered with output we can't read.
  def badge_key
    return level.to_s unless level == :unreachable
    return "stale" if stale_only?
    return "unparseable" if only_unparseable_failures?

    "unreachable"
  end

  def drift?
    versions.size > 1
  end

  # The individual conditions behind #level, for alert rules (spec 8): level picks the single
  # worst one, but a rule on "unhealthy" must still see an unhealthy container on an app that also
  # drifted.
  def unhealthy?
    self.class.unhealthy_rows?(observations)
  end

  def unreachable_or_stale?
    unreachable? || stale?
  end

  # Hosts that didn't answer last round, plus configured hosts never observed.
  def unreachable_hosts
    (observations.reject(&:reachable).map(&:host) + missing_configured_hosts).uniq
  end

  def versions
    self.class.versions_of(observations)
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
          unparseable_output: unparseable?(observation),
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

    def unreachable?
      observations.any? { |o| !o.reachable } || missing_configured_hosts.any?
    end

    def only_unparseable_failures?
      failed = observations.reject(&:reachable)
      missing_configured_hosts.empty? && failed.any? &&
        failed.all? { |o| unparseable?(o) }
    end

    def unparseable?(observation)
      observation.error.to_s.include?(Collectors::ContainerCollector::UNPARSEABLE_OUTPUT_MARKER)
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
