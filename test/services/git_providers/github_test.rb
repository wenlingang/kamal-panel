require "test_helper"

class GitProviders::GithubTest < ActiveSupport::TestCase
  API = "https://api.github.com/repos/acme/shop".freeze

  setup do
    Rails.cache.clear
    @connection = GitConnection.create!(name: "github", provider: "github", token: "ghp_secret_token_1234")
    @client = @connection.client_for("acme/shop")
  end

  def commit_json(sha, message: "Fix checkout\n\nLonger body", login: "octo")
    { sha: sha, html_url: "https://github.com/acme/shop/commit/#{sha}",
      commit: { message: message,
                author: { name: "Octo Cat", date: "2026-11-01T10:00:00Z" },
                committer: { date: "2026-11-01T10:05:00Z" } },
      author: { login: login, avatar_url: "https://avatars.example/#{login}.png" } }
  end

  test "commits are normalized, requested with a bearer token, and on the default branch when none is set" do
    stub_http(
      "GET #{API}" => [ 200, { default_branch: "main" } ],
      "GET #{API}/commits?per_page=2&sha=main" => [ 200, [ commit_json("a" * 40), commit_json("b" * 40) ] ]
    ) do |calls|
      commits = @client.commits(branch: nil, limit: 2)

      assert_equal [ "a" * 40, "b" * 40 ], commits.map(&:sha)
      first = commits.first
      assert_equal "Fix checkout", first.title
      assert_equal "Fix checkout\n\nLonger body", first.message
      assert_equal "Octo Cat", first.author_name
      assert_equal "https://avatars.example/octo.png", first.author_avatar
      assert_equal Time.utc(2026, 11, 1, 10, 5), first.committed_at
      assert_equal "https://github.com/acme/shop/commit/#{'a' * 40}", first.web_url

      assert_equal "Bearer ghp_secret_token_1234", calls.last[:headers]["authorization"]
      assert_equal "application/vnd.github+json", calls.last[:headers]["accept"]
    end
  end

  test "answers are cached, so a second call doesn't go out again" do
    stub_http("GET #{API}/commits?per_page=1&sha=main" => [ 200, [ commit_json("a" * 40) ] ]) do |calls|
      2.times { @client.commits(branch: "main", limit: 1) }

      assert_equal 1, calls.size
    end
  end

  test "rotating the token invalidates the cache" do
    stub_http("GET #{API}/commits?per_page=1&sha=main" => [ 200, [ commit_json("a" * 40) ] ]) do |calls|
      @client.commits(branch: "main", limit: 1)
      travel 1.second do
        @connection.update!(token: "ghp_new_token_5678")
        @connection.client_for("acme/shop").commits(branch: "main", limit: 1)
      end

      assert_equal 2, calls.size
    end
  end

  test "tags carry only the sha; commit_for_tag fetches the commit" do
    stub_http(
      "GET #{API}/tags?per_page=30" => [ 200, [ { name: "v1.2.0", commit: { sha: "c" * 40 } } ] ],
      "GET #{API}/commits/#{'c' * 40}" => [ 200, commit_json("c" * 40, message: "Release 1.2") ]
    ) do
      tag = @client.tags.sole

      assert_equal "v1.2.0", tag.name
      assert_nil tag.commit
      assert_equal "Release 1.2", @client.commit_for_tag(tag).title
    end
  end

  def ci(statuses: [], runs: [])
    sha = "d" * 40
    stub_http(
      "GET #{API}/commits/#{sha}/status" => [ 200, { state: "pending", statuses: statuses } ],
      "GET #{API}/commits/#{sha}/check-runs?per_page=100" => [ 200, { check_runs: runs } ]
    ) { Rails.cache.clear; @client.ci_status(sha) }
  end

  test "CI status combines legacy statuses and check runs" do
    assert_equal "none", ci
    assert_equal "success", ci(statuses: [ { state: "success" } ], runs: [ { status: "completed", conclusion: "success" } ])
    assert_equal "success", ci(runs: [ { status: "completed", conclusion: "skipped" } ])
    assert_equal "failure", ci(statuses: [ { state: "error" } ])
    assert_equal "failure", ci(runs: [ { status: "completed", conclusion: "timed_out" },
                                      { status: "in_progress" } ])
    assert_equal "running", ci(runs: [ { status: "in_progress" }, { status: "completed", conclusion: "success" } ])
    assert_equal "pending", ci(runs: [ { status: "queued" } ])
    assert_equal "pending", ci(statuses: [ { state: "pending" } ])
  end

  test "compare lists the commits between two versions newest first, with a web link" do
    stub_http("GET #{API}/compare/aaaaaaa...bbbbbbb" => [ 200, {
      total_commits: 2, behind_by: 0,
      commits: [ commit_json("1" * 40, message: "older"), commit_json("2" * 40, message: "newer") ]
    } ]) do
      result = @client.compare("aaaaaaa", "bbbbbbb")

      assert_equal %w[newer older], result[:commits].map(&:title)
      assert_equal 2, result[:total]
      assert_equal "https://github.com/acme/shop/compare/aaaaaaa...bbbbbbb", result[:web_url]
    end
  end

  test "URL builders need no network" do
    assert_equal "https://github.com/acme/shop/commit/abc1234", @client.commit_url("abc1234")
    assert_equal "https://github.com/acme/shop/releases/tag/v1.0", @client.tag_url("v1.0")
  end

  test "failures become one error type with a human message" do
    cases = {
      [ 401, { message: "Bad credentials" } ] => "token 无效或已过期",
      [ 404, { message: "Not Found" } ] => "找不到仓库 acme/shop",
      [ 403, {}, { "x-ratelimit-remaining" => "0" } ] => "限流",
      [ 403, {} ] => "没有访问权限",
      [ 502, "<html>" ] => "HTTP 502",
      [ 200, "not json" ] => "无法解析"
    }

    cases.each do |response, message|
      stub_http("GET #{API}" => response) do
        Rails.cache.clear
        error = assert_raises(GitProviders::Error) { @client.default_branch }
        assert_includes error.message, message
      end
    end
  end

  test "a timeout is reported as unreachable, not raised as a timeout" do
    stub_http("GET #{API}" => Net::OpenTimeout) do
      error = assert_raises(GitProviders::Error) { @client.default_branch }
      assert_match "连不上", error.message
    end
  end

  test "the connection check returns the token's login" do
    stub_http("GET https://api.github.com/user" => [ 200, { login: "octo" } ]) do
      assert_equal "octo", @connection.check!
    end
  end
end
