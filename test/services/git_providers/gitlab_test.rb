require "test_helper"

class GitProviders::GitlabTest < ActiveSupport::TestCase
  API = "https://git.example.com/api/v4".freeze
  PROJECT = "#{API}/projects/acme%2Fplatform%2Fshop".freeze

  setup do
    Rails.cache.clear
    @connection = GitConnection.create!(name: "self-hosted", provider: "gitlab", token: "glpat-secret-9999",
                                        api_url: API, web_url: "https://git.example.com/")
    @client = @connection.client_for("acme/platform/shop")
  end

  def commit_json(sha, title: "Fix checkout", email: "dev@example.com")
    { id: sha, title: title, message: "#{title}\n\nbody", author_name: "Dev", author_email: email,
      committed_date: "2026-11-01T10:05:00.000+08:00", web_url: "https://git.example.com/acme/platform/shop/-/commit/#{sha}" }
  end

  test "commits use the encoded project path, PRIVATE-TOKEN, and resolve avatars per author" do
    stub_http(
      "GET #{PROJECT}/repository/commits?per_page=2&ref_name=release" =>
        [ 200, [ commit_json("a" * 40), commit_json("b" * 40) ] ],
      "GET #{API}/avatar?email=dev%40example.com&size=64" => [ 200, { avatar_url: "https://git.example.com/avatar.png" } ]
    ) do |calls|
      commits = @client.commits(branch: "release", limit: 2)

      assert_equal [ "a" * 40, "b" * 40 ], commits.map(&:sha)
      assert_equal "Fix checkout", commits.first.title
      assert_equal "https://git.example.com/avatar.png", commits.first.author_avatar
      assert_equal Time.utc(2026, 11, 1, 2, 5), commits.first.committed_at
      assert_equal 1, calls.count { |call| call[:key].include?("/avatar") }, "one lookup per distinct author"
      assert(calls.all? { |call| call[:headers]["private-token"] == "glpat-secret-9999" })
    end
  end

  test "a missing avatar doesn't fail the listing" do
    stub_http(
      "GET #{PROJECT}/repository/commits?per_page=1&ref_name=main" => [ 200, [ commit_json("a" * 40) ] ],
      %r{/avatar} => [ 500, {} ]
    ) do
      assert_nil @client.commits(branch: "main", limit: 1).sole.author_avatar
    end
  end

  test "tags come with their commit, no second request" do
    stub_http(
      "GET #{PROJECT}/repository/tags?per_page=30" =>
        [ 200, [ { name: "v2.0.0", commit: commit_json("c" * 40, title: "Release 2", email: nil) } ] ]
    ) do
      tag = @client.tags.sole

      assert_equal "v2.0.0", tag.name
      assert_equal "c" * 40, tag.sha
      assert_equal "Release 2", @client.commit_for_tag(tag).title
    end
  end

  test "CI status follows the last pipeline" do
    { "success" => "success", "failed" => "failure", "canceled" => "failure", "running" => "running",
      "created" => "pending", "manual" => "pending", "skipped" => "none" }.each do |pipeline, expected|
      Rails.cache.clear
      stub_http("GET #{PROJECT}/repository/commits/abc1234" => [ 200, { id: "abc1234", last_pipeline: { status: pipeline } } ]) do
        assert_equal expected, @client.ci_status("abc1234"), pipeline
      end
    end
  end

  test "without a pipeline, CI status falls back to commit statuses" do
    stub_http(
      "GET #{PROJECT}/repository/commits/abc1234" => [ 200, { id: "abc1234", last_pipeline: nil } ],
      "GET #{PROJECT}/repository/commits/abc1234/statuses" => [ 200, [ { status: "success" }, { status: "running" } ] ]
    ) do
      assert_equal "running", @client.ci_status("abc1234")
    end

    Rails.cache.clear
    stub_http(
      "GET #{PROJECT}/repository/commits/abc1234" => [ 200, { id: "abc1234" } ],
      "GET #{PROJECT}/repository/commits/abc1234/statuses" => [ 200, [] ]
    ) do
      assert_equal "none", @client.ci_status("abc1234")
    end
  end

  test "compare and web links use GitLab's /-/ paths" do
    stub_http(
      "GET #{PROJECT}/repository/compare?from=v1&to=v2" => [ 200, { commits: [ commit_json("1" * 40, email: nil) ] } ]
    ) do
      result = @client.compare("v1", "v2")

      assert_equal 1, result[:commits].size
      assert_equal "https://git.example.com/acme/platform/shop/-/compare/v1...v2", result[:web_url]
    end
    assert_equal "https://git.example.com/acme/platform/shop/-/commit/abc", @client.commit_url("abc")
    assert_equal "https://git.example.com/acme/platform/shop/-/tags/v1", @client.tag_url("v1")
  end

  test "the connection check returns the username" do
    stub_http("GET #{API}/user" => [ 200, { username: "deployer" } ]) do
      assert_equal "deployer", @connection.check!
    end
  end
end
