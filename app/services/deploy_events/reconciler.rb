module DeployEvents
  # Backfill onto DeployEvent the fact that "the panel actually saw this version running" (spec 03
  # §5).
  class Reconciler
    RUNNING_STATUSES = %w[running restarting].freeze

    def self.call(managed_app)
      new(managed_app).call
    end

    def initialize(managed_app)
      @managed_app = managed_app
    end

    def call
      running_versions.each do |version, observed_at|
        managed_app.deploy_events
                   .where(version: version, observed_at: nil)
                   .update_all(observed_at: observed_at, updated_at: Time.current)
      end
    end

    private
      attr_reader :managed_app

      # version => the time of the earliest running observation of that version
      def running_versions
        Observation.latest_for(managed_app)
                   .select { |o| RUNNING_STATUSES.include?(o.docker_status) && o.version.present? }
                   .group_by(&:version)
                   .transform_values { |rows| rows.map(&:observed_at).min }
      end
  end
end
