require "test_helper"

class AppDeploysControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  API = "https://api.github.com/repos/acme/blog".freeze
  REGISTRY = "https://registry.example.com/v2/example/blog/manifests".freeze
  LIVE = ("a" * 40).freeze
  NEW = ("b" * 40).freeze
  BROKEN = ("c" * 40).freeze

  setup do
    Rails.cache.clear
    @connection = GitConnection.create!(name: "github", provider: "github", token: "ghp_token_for_tests")
    @managed_app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                                      destination: "production", git_connection: @connection,
                                      repository: "acme/blog",
                                      ssh_credential: Credential.create!(kind: "ssh_key", name: "key",
                                                                         value: FakeHost.private_key))
    Observation.create!(managed_app: @managed_app, host: "127.0.0.1", role: "web", version: LIVE,
                        container_name: "blog-web-production-#{LIVE}", docker_status: "running",
                        reachable: true, observed_at: Time.current)
  end

  def commit_json(sha, title)
    { sha: sha, html_url: "https://github.com/acme/blog/commit/#{sha}",
      commit: { message: title, author: { name: "Dev", date: "2026-11-01T10:00:00Z" },
                committer: { date: "2026-11-01T10:00:00Z" } },
      author: { login: "dev", avatar_url: "https://avatars.example/dev.png" } }
  end

  def ci_routes(sha, conclusion)
    { "GET #{API}/commits/#{sha}/status" => [ 200, { statuses: [] } ],
      "GET #{API}/commits/#{sha}/check-runs?per_page=100" =>
        [ 200, { check_runs: [ { status: "completed", conclusion: conclusion } ] } ] }
  end

  def version_list_routes
    {
      "GET #{API}" => [ 200, { default_branch: "main" } ],
      "GET #{API}/commits?per_page=#{DeployCandidates::LIMIT}&sha=main" =>
        [ 200, [ commit_json(BROKEN, "Broken build"), commit_json(NEW, "Add search"), commit_json(LIVE, "Fix cart") ] ],
      "HEAD #{REGISTRY}/#{BROKEN}" => [ 404 ],
      "HEAD #{REGISTRY}/#{NEW}" => [ 200 ],
      "HEAD #{REGISTRY}/#{LIVE}" => [ 200 ]
    }.merge(ci_routes(BROKEN, "failure"), ci_routes(NEW, "success"), ci_routes(LIVE, "success"))
  end

  test "ops and non-member developers can't see versions, the confirm page, or deploy" do
    [ users(:one), users(:three) ].each do |user|
      sign_in_as user

      get versions_managed_app_deploy_path(@managed_app)
      assert_redirected_to root_path
      get new_managed_app_deploy_path(@managed_app, version: NEW)
      assert_redirected_to root_path

      assert_no_difference -> { AuditLog.count } do
        assert_no_enqueued_jobs(only: RunActionJob) do
          post managed_app_deploy_path(@managed_app), params: { version: NEW }
        end
      end
    end
  end

  test "confirming writes the audit row first, queues the run and opens its output page" do
    sign_in_as users(:two)

    assert_enqueued_with(job: RunActionJob) do
      post managed_app_deploy_path(@managed_app), params: { version: NEW }
    end

    log = AuditLog.last
    assert_equal [ "deploy", NEW, "pending" ], [ log.action_name, log.target_version, log.result ]
    assert_equal [ "127.0.0.1" ], log.hosts
    assert_redirected_to managed_app_action_path(@managed_app, log)
  end
end
