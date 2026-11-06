require "test_helper"

class DeploysControllerTest < ActionDispatch::IntegrationTest
  setup do
    yaml = file_fixture("simple_deploy.yml").read
    @connection = GitConnection.create!(name: "github", provider: "github", token: "ghp_token_for_tests")
    @blog = ManagedApp.create!(name: "blog", config_yaml: yaml, git_connection: @connection, repository: "acme/blog")
    @shop = ManagedApp.create!(name: "shop", config_yaml: yaml.sub("service: blog", "service: shop"))
  end

  test "lists deploys from every source across apps, newest first, with commit links" do
    sha = "a" * 40
    log = AuditLog.create!(user: users(:two), managed_app: @blog, action_name: "deploy", target_version: sha,
                           hosts: [], result: "failure", created_at: 5.minutes.ago)
    @blog.deploy_events.create!(source: "panel", version: sha, performer: "admin", command: "deploy",
                                started_at: 5.minutes.ago, failed_at: 4.minutes.ago, audit_log: log)
    @shop.deploy_events.create!(source: "hook", version: "v2", performer: "ci", command: "deploy",
                                started_at: 2.minutes.ago, succeeded_at: 1.minute.ago)
    # Refused by the lock: no event, only its audit row.
    AuditLog.create!(user: users(:two), managed_app: @shop, action_name: "rollback", target_version: "v1",
                     hosts: [], result: "failure", command: "(未执行)", created_at: 10.minutes.ago)
    sign_in_as users(:one)

    get deploys_path

    assert_response :success
    rows = css_select("table.deploy-feed tbody tr")
    assert_equal 3, rows.size
    assert_match "shop", rows[0].text
    assert_match "成功", rows[0].text
    assert_match "blog", rows[1].text
    assert_match "失败", rows[1].text
    assert_match "未执行", rows[2].text
    assert_select "a[href=?]", "https://github.com/acme/blog/commit/#{sha}", text: "aaaaaaa"
    # Ops can read the feed but not deploy, so no output links and no "new deploy".
    assert_select "a[href=?]", managed_app_action_path(@blog, log), count: 0
    assert_select "a[href=?]", new_deploy_path, count: 0
  end

  test "filters by app" do
    @blog.deploy_events.create!(source: "inferred", version: "v1", succeeded_at: 1.minute.ago)
    @shop.deploy_events.create!(source: "inferred", version: "v9", succeeded_at: 1.minute.ago)
    sign_in_as users(:two)

    get deploys_path(app_id: @shop.id)

    assert_select "table.deploy-feed tbody tr", count: 1
    assert_select "table.deploy-feed", text: /v9/
  end

  test "admins get output links and the new-deploy entry" do
    log = AuditLog.create!(user: users(:two), managed_app: @blog, action_name: "deploy", target_version: "v3",
                           hosts: [], result: "success", created_at: 1.minute.ago)
    @blog.deploy_events.create!(source: "panel", version: "v3", started_at: 1.minute.ago,
                                succeeded_at: Time.current, audit_log: log)
    sign_in_as users(:two)

    get deploys_path

    assert_select "table.deploy-feed tbody tr", count: 1, text: /v3/
    assert_select "a[href=?]", managed_app_action_path(@blog, log)
    assert_select "a[href=?]", new_deploy_path
  end

  test "new deploy lists only the apps the person may deploy" do
    AppMembership.create!(user: users(:three), managed_app: @shop)
    sign_in_as users(:three)

    get new_deploy_path

    assert_select "a[href=?]", "/apps/#{@shop.id}?tab=deploy"
    assert_select "a[href=?]", "/apps/#{@blog.id}?tab=deploy", count: 0
  end

  test "deactivated apps are left out" do
    @blog.deploy_events.create!(source: "inferred", version: "v1", succeeded_at: 1.minute.ago)
    @blog.deactivate!
    sign_in_as users(:two)

    get deploys_path

    assert_select "table.deploy-feed", count: 0
  end
end
