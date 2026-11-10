module GitProviders
  # Gitee's v5 API is modelled on GitHub's: same /repos/owner/repo paths and commit payloads. Only
  # the differences live here.
  class Gitee < Github
    # Gitee has no commit status or check-run API (both 404), so there is nothing to report.
    def ci_status(_sha) = "none"

    # Without sort the listing comes back oldest first; newest first is what the deploy picker wants.
    def tags(limit: 30)
      cached("tags", limit) do
        get_json("#{repo_path}/tags", sort: "updated", direction: "desc", per_page: limit).map do |data|
          Tag.new(name: data["name"], sha: data.dig("commit", "sha"), commit: nil)
        end
      end
    end

    # The order of Gitee's compare payload isn't documented, and there is no total_commits /
    # behind_by, so sort here (newest first, as on the other providers) and count what came back.
    def compare(from, to)
      cached("compare", from, to) do
        data = get_json("#{repo_path}/compare/#{segment(from)}...#{segment(to)}")
        commits = data["commits"].to_a.map { |c| commit_from(c) }.sort_by { |c| c.committed_at || Time.at(0) }.reverse
        { commits: commits, total: commits.size, behind_by: 0, web_url: compare_url(from, to) }
      end
    end

    # A tag only has a release page if someone made a release; the tree view always exists.
    def tag_url(name) = "#{repo_web_url}/tree/#{segment(name)}"

    private
      # Gitee also takes ?access_token=, but a header keeps the token out of URLs (and so out of
      # error messages and logs).
      def auth_headers = { "Authorization" => "token #{token}" }

      def accept_header = "application/json"
  end
end
