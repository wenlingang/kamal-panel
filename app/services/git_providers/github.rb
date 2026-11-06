module GitProviders
  class Github < Base
    # Check-run conclusions that mean the commit is not fit to ship. neutral / skipped don't.
    FAILED_CONCLUSIONS = %w[failure timed_out cancelled action_required startup_failure].freeze

    def current_user = get_json("/user")["login"]

    def default_branch
      cached("default_branch") { get_json(repo_path)["default_branch"] }
    end

    def commits(branch: nil, limit: 30)
      branch = branch.presence || default_branch
      cached("commits", branch, limit) do
        get_json("#{repo_path}/commits", sha: branch, per_page: limit).map { |data| commit_from(data) }
      end
    end

    def commit(sha)
      cached("commit", sha) { commit_from(get_json("#{repo_path}/commits/#{segment(sha)}")) }
    end

    # GitHub's tag listing carries only the sha; the commit is fetched per tag when shown.
    def tags(limit: 30)
      cached("tags", limit) do
        get_json("#{repo_path}/tags", per_page: limit).map do |data|
          Tag.new(name: data["name"], sha: data.dig("commit", "sha"), commit: nil)
        end
      end
    end

    # Two systems report CI on GitHub: the legacy combined status (external CIs) and check runs
    # (Actions and apps). Either can be the one that matters, so both are read.
    def ci_status(sha)
      cached("ci", sha) do
        combined = get_json("#{repo_path}/commits/#{segment(sha)}/status")
        runs = get_json("#{repo_path}/commits/#{segment(sha)}/check-runs", per_page: 100)["check_runs"].to_a
        combine(combined, runs)
      end
    end

    def compare(from, to)
      cached("compare", from, to) do
        data = get_json("#{repo_path}/compare/#{segment(from)}...#{segment(to)}")
        { commits: data["commits"].to_a.map { |c| commit_from(c) }.reverse,
          total: data["total_commits"].to_i,
          behind_by: data["behind_by"].to_i,
          web_url: compare_url(from, to) }
      end
    end

    def commit_url(sha) = "#{repo_web_url}/commit/#{segment(sha)}"
    def tag_url(name) = "#{repo_web_url}/releases/tag/#{segment(name)}"
    def compare_url(from, to) = "#{repo_web_url}/compare/#{segment(from)}...#{segment(to)}"

    private
      def repo_path = "/repos/#{repository}"

      def auth_headers = { "Authorization" => "Bearer #{token}", "X-GitHub-Api-Version" => "2022-11-28" }

      def accept_header = "application/vnd.github+json"

      def commit_from(data)
        message = data.dig("commit", "message").to_s
        Commit.new(
          sha: data["sha"],
          title: message.lines.first.to_s.strip,
          message: message,
          author_name: data.dig("commit", "author", "name") || data.dig("author", "login"),
          author_avatar: data.dig("author", "avatar_url"),
          committed_at: parse_time(data.dig("commit", "committer", "date") || data.dig("commit", "author", "date")),
          web_url: data["html_url"] || commit_url(data["sha"])
        )
      end

      def combine(combined, runs)
        statuses = combined["statuses"].to_a
        return "none" if statuses.empty? && runs.empty?

        failed = statuses.any? { |s| %w[failure error].include?(s["state"]) } ||
                 runs.any? { |r| r["status"] == "completed" && FAILED_CONCLUSIONS.include?(r["conclusion"]) }
        return "failure" if failed
        return "running" if runs.any? { |r| r["status"] == "in_progress" }
        return "pending" if statuses.any? { |s| s["state"] == "pending" } ||
                            runs.any? { |r| r["status"] != "completed" }

        "success"
      end
  end
end
