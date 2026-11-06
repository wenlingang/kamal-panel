# The rows of the deploy tab's version list: recent commits (or tags, for tag-versioned apps) with
# what is known about each — CI status, whether the image is in the registry, whether it is live.
#
# Remote calls (Git platform + registry) run on a few threads at once, inside the version-list
# frame's own request: the page around it renders from the database, and one request doing ~30
# small calls concurrently beats one frame per row holding a server thread each.
class DeployCandidates
  # How many versions are listed and checked. A deploy almost always picks one of the newest few.
  LIMIT = 15

  Row = Data.define(:version, :commit, :ci, :image, :live) do
    # Why the row can't be picked, or nil. Unknown CI / image status warns but doesn't block:
    # the panel may simply lack credentials to ask.
    def blocker
      if ci == "failure" then :ci_failed
      elsif image == :missing then :image_missing
      end
    end

    def warnings
      [ (:ci_not_success unless %w[success failure].include?(ci)),
        (:image_unknown if image == :unknown) ].compact
    end
  end

  def initialize(managed_app, live_versions: [])
    @managed_app = managed_app
    @live_versions = live_versions
  end

  # Raises GitProviders::Error when the list itself can't be had; per-row CI / registry failures
  # only turn that row's status into "unknown".
  def rows
    client = managed_app.git_client
    entries = list_entries(client)
    probe = registry_probe

    details = OutboundHttp.parallel_map(entries) do |version, commit_or_tag|
      commit = commit_or_tag.is_a?(GitProviders::Tag) ? client.commit_for_tag(commit_or_tag) : commit_or_tag
      [ commit, ci_status(client, commit&.sha), probe ? probe.status(version) : :unknown ]
    end

    entries.zip(details).map do |(version, _), detail|
      commit, ci, image = detail.is_a?(Exception) ? [ nil, "unknown", :unknown ] : detail
      Row.new(version:, commit:, ci:, image:, live: live_versions.include?(version))
    end
  end

  private
    attr_reader :managed_app, :live_versions

    def list_entries(client)
      if managed_app.version_format == "tag"
        client.tags(limit: LIMIT).map { |tag| [ tag.name, tag ] }
      else
        client.commits(branch: managed_app.git_branch, limit: LIMIT)
              .map { |commit| [ managed_app.version_for(sha: commit.sha), commit ] }
      end
    end

    def ci_status(client, sha)
      return "unknown" if sha.blank?

      client.ci_status(sha)
    rescue GitProviders::Error
      "unknown"
    end

    # nil when the config can't be parsed; the image column then reads "unknown" everywhere.
    def registry_probe
      RegistryProbe.new(managed_app)
    rescue Kamal::ConfigParser::ParseError
      nil
    end
end
