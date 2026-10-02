module DeployEvents
  # Infer deploy events from observations (sub-design 05).
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

      # The baseline check is hoisted to the very front: the first convergence
      # (last_converged_version is still nil)
      first_convergence = managed_app.last_converged_version.nil?

      # The comparison uses the boundary from [before the update]: whether this report arrived
      # within the current convergence period.
      record_inferred(version, converged_at) if !first_convergence && !hook_already_reported?(version)

      # a wrong time boundary to compare against.
      managed_app.update_columns(last_converged_version: version,
                                 last_converged_at: converged_at,
                                 updated_at: Time.current)
    end

    private
      attr_reader :managed_app

      # => [version, converged_at] or [nil, nil]
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
          # cannot infer when it started;
          # leaving it blank is more honest than making up an "unknown".
          started_at: nil, performer: nil, command: nil,
          succeeded_at: converged_at, observed_at: converged_at
        )
      end
  end
end
