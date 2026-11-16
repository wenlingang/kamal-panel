# The other environments of the same app, as places to promote a version from. Kamal runs one app
# in several destinations (staging, production...) from the same image; the panel manages each
# destination as its own app, and two apps are the same app in different environments when they
# deploy the same image repository with different destinations.
#
# Promoting deploys the version the source runs now, already built and pushed: nothing is rebuilt,
# so production gets exactly the image staging was checked with.
class PromotionSources
  Source = Data.define(:app, :version, :level, :deployed_at, :blocker) do
    def ready? = blocker.nil?
  end

  def initialize(managed_app)
    @managed_app = managed_app
  end

  # [Source], one per sibling environment, in name order. A source that can't be promoted from
  # (versions differ between its hosts, it's unhealthy, nothing observed yet) says why in blocker.
  def sources
    repository = repository_of(managed_app)
    return [] if repository.nil?

    ManagedApp.active.where.not(id: managed_app.id).where(last_poll_error: nil).order(:name).filter_map do |app|
      next unless repository_of(app) == repository && app.destination.to_s != managed_app.destination.to_s

      source_for(app)
    end
  end

  private
    attr_reader :managed_app

    def repository_of(app)
      app.parsed_config.repository.presence
    rescue Kamal::ConfigParser::ParseError
      nil
    end

    def source_for(app)
      status = ManagedAppStatus.new(app)
      versions = status.versions
      version = versions.first if versions.one?
      deployed_at = app.deploy_events.not_failed.where(version:).maximum(:succeeded_at) if version

      blocker =
        if versions.empty? then "no_version"
        elsif versions.many? then "drift"
        elsif status.level == :unhealthy then "unhealthy"
        end

      Source.new(app:, version:, level: status.level, deployed_at:, blocker:)
    end
end
