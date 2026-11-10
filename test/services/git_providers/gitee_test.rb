require "test_helper"

class GitProviders::GiteeTest < ActiveSupport::TestCase
  API = "https://gitee.com/api/v5/repos/acme/web".freeze

  setup do
    Rails.cache.clear
    @connection = GitConnection.create!(name: "gitee", provider: "gitee", token: "gitee_token_1234")
    @client = @connection.client_for("acme/web")
  end

  def commit_json(sha, at)
    { sha: sha, html_url: "https://gitee.com/acme/web/commit/#{sha}",
      author: { login: "dev", avatar_url: "https://gitee.com/a.png" },
      commit: { message: "fix: #{sha}\n\nbody", author: { name: "Dev", date: at }, committer: { name: "Dev", date: at } } }
  end

  test "defaults to the public gitee.com addresses" do
    assert_equal "https://gitee.com/api/v5", @connection.api_url
    assert_equal "https://gitee.com", @connection.web_url
    assert_instance_of GitProviders::Gitee, @client
  end

  test "sends the token in a header, never in the URL" do
    stub_http("GET https://gitee.com/api/v5/user" => [ 200, { login: "me" } ]) do |calls|
      assert_equal "me", @connection.check!
      assert_equal "token gitee_token_1234", calls.first[:headers]["authorization"]
      assert_not_includes calls.first[:key], "gitee_token_1234"
    end
  end

  test "reads commits and tags, tags newest first" do
    stub_http(
      "GET #{API}" => [ 200, { default_branch: "master" } ],
      "GET #{API}/commits?per_page=30&sha=master" => [ 200, [ commit_json("abc", "2026-04-27T15:58:51+08:00") ] ],
      "GET #{API}/tags?direction=desc&per_page=30&sort=updated" => [ 200, [ { name: "v2", commit: { sha: "abc" } } ] ]
    ) do
      commit = @client.commits.first
      assert_equal "abc", commit.sha
      assert_equal "fix: abc", commit.title
      assert_equal "https://gitee.com/a.png", commit.author_avatar

      tag = @client.tags.first
      assert_equal [ "v2", "abc" ], [ tag.name, tag.sha ]
    end
  end

  test "compare sorts newest first and counts what came back" do
    stub_http("GET #{API}/compare/v1...v2" => [ 200, { commits: [
      commit_json("old", "2026-04-25T10:00:00+08:00"), commit_json("new", "2026-04-27T10:00:00+08:00")
    ] } ]) do
      result = @client.compare("v1", "v2")
      assert_equal %w[new old], result[:commits].map(&:sha)
      assert_equal 2, result[:total]
      assert_equal "https://gitee.com/acme/web/compare/v1...v2", result[:web_url]
    end
  end

  test "has no CI status and links tags to the tree view" do
    stub_http({}) do |calls|
      assert_equal "none", @client.ci_status("abc")
      assert_empty calls
    end
    assert_equal "https://gitee.com/acme/web/tree/v2", @client.tag_url("v2")
    assert_equal "https://gitee.com/acme/web/commit/abc", @client.commit_url("abc")
  end
end
