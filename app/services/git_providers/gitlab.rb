module GitProviders
  class Gitlab < Base
    # Pipeline / commit-status values, folded into the panel's five.
    CI_MAP = {
      "success" => "success",
      "failed" => "failure", "canceled" => "failure",
      "running" => "running",
      "pending" => "pending", "created" => "pending", "waiting_for_resource" => "pending",
      "preparing" => "pending", "scheduled" => "pending", "manual" => "pending",
      "skipped" => "none"
    }.freeze

    AVATAR_TTL = 1.day

    def current_user = get_json("/user")["username"]

    def default_branch
      cached("default_branch") { get_json(project_path)["default_branch"] }
    end

    def commits(branch: nil, limit: 30)
      branch = branch.presence || default_branch
      cached("commits", branch, limit) do
        with_avatars(get_json("#{project_path}/repository/commits", ref_name: branch, per_page: limit))
      end
    end

    def commit(sha)
      cached("commit", sha) do
        with_avatars([ get_json("#{project_path}/repository/commits/#{segment(sha)}") ]).first
      end
    end

    # GitLab's tag listing embeds the commit, so no second round trip per tag.
    def tags(limit: 30)
      cached("tags", limit) do
        data = get_json("#{project_path}/repository/tags", per_page: limit)
        commits = with_avatars(data.map { |tag| tag["commit"] || {} })
        data.zip(commits).map do |tag, commit|
          Tag.new(name: tag["name"], sha: tag.dig("commit", "id"), commit: commit)
        end
      end
    end

    # The commit's last pipeline is what GitLab itself shows next to a commit; external CIs that
    # only post commit statuses have no pipeline, so fall back to those.
    def ci_status(sha)
      cached("ci", sha) do
        pipeline = get_json("#{project_path}/repository/commits/#{segment(sha)}")["last_pipeline"]
        if pipeline
          CI_MAP.fetch(pipeline["status"].to_s, "pending")
        else
          statuses = get_json("#{project_path}/repository/commits/#{segment(sha)}/statuses").map { |s| CI_MAP[s["status"].to_s] }
          worst(statuses.compact)
        end
      end
    end

    def compare(from, to)
      cached("compare", from, to) do
        data = get_json("#{project_path}/repository/compare", from: from, to: to)
        commits = with_avatars(data["commits"].to_a).sort_by { |c| c.committed_at || Time.at(0) }.reverse
        { commits: commits, total: commits.size, behind_by: 0, web_url: compare_url(from, to) }
      end
    end

    def commit_url(sha) = "#{repo_web_url}/-/commit/#{segment(sha)}"
    def tag_url(name) = "#{repo_web_url}/-/tags/#{segment(name)}"
    def compare_url(from, to) = "#{repo_web_url}/-/compare/#{segment(from)}...#{segment(to)}"

    private
      # Group paths contain slashes; the API wants the whole path as one encoded segment.
      def project_path = "/projects/#{segment(repository)}"

      def auth_headers = { "PRIVATE-TOKEN" => token.to_s }

      def worst(statuses)
        return "none" if statuses.empty?

        GitProviders::CI_STATUSES.find { |status| statuses.include?(status) }
      end

      # GitLab commits name an email, not an account; the avatar endpoint resolves it. Looked up
      # once per distinct author and kept a day, since avatars rarely change.
      def with_avatars(rows)
        emails = rows.filter_map { |row| row["author_email"].presence }.uniq
        avatars = emails.zip(OutboundHttp.parallel_map(emails) { |email| avatar_for(email) }).to_h
        rows.map { |row| commit_from(row, avatars[row["author_email"]]) }
      end

      def avatar_for(email)
        cached("avatar", email, expires_in: AVATAR_TTL) { get_json("/avatar", email: email, size: 64)["avatar_url"] }
      rescue Error
        nil
      end

      def commit_from(data, avatar)
        Commit.new(
          sha: data["id"],
          title: data["title"].to_s,
          message: data["message"].to_s,
          author_name: data["author_name"],
          author_avatar: avatar.is_a?(String) ? avatar : nil,
          committed_at: parse_time(data["committed_date"] || data["created_at"]),
          web_url: data["web_url"] || commit_url(data["id"])
        )
      end
  end
end
