# What the deploy confirm page shows about going from the running version to the target: the
# commits in between, CI and image status of the target, and anything worth a second look.
# Every remote answer is optional — when the Git platform or registry can't be reached the page
# still renders, says so, and the deploy can go ahead.
class DeployPreview
  # The compare list is for reading, not auditing; the link has the rest.
  COMMIT_LIMIT = 50

  def initialize(managed_app, version)
    @managed_app = managed_app
    @version = version
  end

  attr_reader :managed_app, :version

  def current_versions = @current_versions ||= ManagedAppStatus.new(managed_app).versions

  # The one version every host runs, or nil (nothing observed yet, or drift).
  def current_version = (current_versions.first if current_versions.one?)

  def drift? = current_versions.size > 1
  def redeploy? = current_version == version

  def target_commit = remote[:commit]
  def ci = remote[:ci] || "unknown"
  def image = remote[:image] || :unknown
  def comparison = remote[:compare]
  def git_error = remote[:error]

  def compare_url
    return nil unless managed_app.git_configured? && current_version && !redeploy?

    managed_app.git_client.compare_url(current_version, version)
  end

  def warnings
    [ (:drift if drift?),
      (:redeploy if redeploy?),
      (:ci_failed if ci == "failure"),
      (:ci_not_success if %w[running pending none unknown].include?(ci)),
      (:image_missing if image == :missing),
      (:image_unknown if image == :unknown) ].compact
  end

  private
    # Independent remote questions, asked at once. Both providers accept any ref (full or short
    # sha, tag) where a sha goes, so the target's commit and CI status don't wait on each other.
    # Clients and the probe are built here, on the request thread: the workers must not touch
    # the database.
    def remote
      @remote ||= begin
        probe = registry_probe
        tasks = { image: -> { probe ? probe.status(version) : :unknown } }

        if managed_app.git_configured?
          client = managed_app.git_client
          tasks[:commit] = -> { client.commit(version) }
          tasks[:ci] = -> { client.ci_status(version) }
          tasks[:compare] = -> { client.compare(current_version, version) } if current_version && !redeploy?
        end

        collect(tasks.keys.zip(OutboundHttp.parallel_map(tasks.values, &:call)).to_h)
      end
    end

    def collect(answers)
      error = answers.values.find { |value| value.is_a?(GitProviders::Error) }
      # Anything else that went wrong on a worker is a bug, not an outage: stay loud.
      unexpected = answers.values.find { |value| value.is_a?(Exception) && !value.is_a?(GitProviders::Error) }
      raise unexpected if unexpected

      ok = answers.reject { |_key, value| value.is_a?(Exception) }
      compare = ok[:compare]&.then { |c| c.merge(commits: c[:commits].first(COMMIT_LIMIT)) }

      { commit: ok[:commit], ci: ok[:ci], image: ok[:image], compare:, error: }
    end

    def registry_probe
      RegistryProbe.new(managed_app)
    rescue Kamal::ConfigParser::ParseError
      nil
    end
end
