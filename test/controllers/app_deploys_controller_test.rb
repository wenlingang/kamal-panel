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

  test "a member developer can deploy" do
    AppMembership.create!(user: users(:three), managed_app: @managed_app)
    sign_in_as users(:three)

    assert_enqueued_with(job: RunActionJob) do
      post managed_app_deploy_path(@managed_app), params: { version: NEW }
    end
    assert_equal "deploy", AuditLog.last.action_name
  end

  test "the deploy tab renders without calling out: the version list is a frame" do
    sign_in_as users(:two)

    stub_http({}) do |calls|
      get managed_app_path(@managed_app, tab: "deploy")

      assert_response :success
      assert_empty calls
    end
    assert_select "turbo-frame#deploy_versions[src=?]", versions_managed_app_deploy_path(@managed_app)
    assert_select "form[action=?][method=get] input[name=version]", new_managed_app_deploy_path(@managed_app)
    assert_select ".head-actions a[href=?]", managed_app_path(@managed_app, tab: "deploy")
  end

  test "without a repository the tab offers manual entry and a way to configure one" do
    @managed_app.update!(git_connection: nil, repository: nil)
    sign_in_as users(:two)

    get managed_app_path(@managed_app, tab: "deploy")

    assert_select "turbo-frame#deploy_versions", count: 0
    assert_select "a[href=?]", edit_managed_app_path(@managed_app, anchor: "git")
    assert_select "form[action=?] input[name=version]", new_managed_app_deploy_path(@managed_app)
  end

  test "the version list shows CI, image and live status, and blocks versions that can't ship" do
    sign_in_as users(:two)

    stub_http(version_list_routes) { get versions_managed_app_deploy_path(@managed_app) }

    assert_response :success
    assert_select "turbo-frame#deploy_versions"
    assert_select "tr", text: /Add search/ do
      assert_select "a[href=?]", new_managed_app_deploy_path(@managed_app, version: NEW)
      assert_select ".status-badge", text: "CI 通过"
      assert_select ".status-badge", text: "镜像就绪"
      assert_select "img.avatar[src=?]", "https://avatars.example/dev.png"
    end
    assert_select "tr.is-blocked", text: /Broken build/ do
      assert_select "a[href=?]", new_managed_app_deploy_path(@managed_app, version: BROKEN), count: 0
      assert_select ".row-blocker", text: "CI 失败，不能发布"
    end
    assert_select "tr", text: /Fix cart/ do
      assert_select ".status-badge", text: "线上"
    end
  end

  test "a Git platform outage degrades the list, it doesn't break it" do
    sign_in_as users(:two)

    stub_http("GET #{API}" => [ 503, "down" ]) { get versions_managed_app_deploy_path(@managed_app) }

    assert_response :success
    assert_select "turbo-frame#deploy_versions .callout-warn", text: /Git 平台暂时不可用：平台返回了 HTTP 503/
  end

  test "the confirm page shows current → target, the commits between, scope and warnings" do
    sign_in_as users(:two)
    routes = {
      "GET #{API}/commits/#{NEW}" => [ 200, commit_json(NEW, "Add search") ],
      "GET #{API}/compare/#{LIVE}...#{NEW}" =>
        [ 200, { total_commits: 1, behind_by: 0, commits: [ commit_json(NEW, "Add search") ] } ],
      "HEAD #{REGISTRY}/#{NEW}" => [ 401, nil, { "WWW-Authenticate" => 'Basic realm="r"' } ]
    }.merge(ci_routes(NEW, "success"))

    stub_http(routes) { get new_managed_app_deploy_path(@managed_app, version: NEW) }

    assert_response :success
    assert_select ".deploy-route a[href=?]", "https://github.com/acme/blog/commit/#{LIVE}"
    assert_select ".deploy-route a[href=?]", "https://github.com/acme/blog/commit/#{NEW}"
    assert_select ".commit-list li", text: /Add search/
    assert_select "a[href=?]", "https://github.com/acme/blog/compare/#{LIVE}...#{NEW}"
    assert_select ".status-badge", text: "CI 通过"
    assert_select ".callout-warn li", text: /无法确认镜像是否已推送/
    assert_select "dd", text: /web\s+127\.0\.0\.1/
    assert_select "form[action=?] button", managed_app_deploy_path(@managed_app), text: /确认发布/
  end

  test "the confirm page still works when the Git platform is down" do
    sign_in_as users(:two)

    stub_http(%r{api\.github\.com} => Errno::ECONNREFUSED, %r{registry} => [ 200 ]) do
      get new_managed_app_deploy_path(@managed_app, version: NEW)
    end

    assert_response :success
    assert_select ".callout-warn", text: /Git 平台暂时不可用/
    assert_select "form[action=?] button", managed_app_deploy_path(@managed_app), text: /确认发布/
  end

  test "an invalid version is refused before anything is audited" do
    sign_in_as users(:two)

    get new_managed_app_deploy_path(@managed_app, version: "--skip-push")
    assert_redirected_to managed_app_path(@managed_app, tab: "deploy")

    assert_no_difference -> { AuditLog.count } do
      post managed_app_deploy_path(@managed_app), params: { version: "-x" }
    end
    assert_redirected_to managed_app_path(@managed_app, tab: "deploy")
    assert_match "版本号不合法", flash[:alert]
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

  test "the generic actions endpoint validates deploy versions too" do
    sign_in_as users(:two)

    assert_no_difference -> { AuditLog.count } do
      post managed_app_actions_path(@managed_app), params: { name: "deploy", version: "--help" }
    end
    assert_match "版本号不合法", flash[:alert]
  end
end
