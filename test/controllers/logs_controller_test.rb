require "test_helper"

class LogsControllerTest < ActionDispatch::IntegrationTest
  setup do
    # The rate limit counts in the cache; a previous test's query must not count against this one.
    Rails.cache.clear
    @credential = Credential.create!(kind: "ssh_key", name: "key", value: FakeHost.private_key)
    @blog = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                               destination: "production", ssh_credential: @credential)
    @shop = ManagedApp.create!(name: "shop", config_yaml: file_fixture("accessory_deploy.yml").read,
                               destination: "staging")
    @developer = users(:three)
    AppMembership.create!(user: @developer, managed_app: @blog)
  end

  test "the sidebar has a Logs entry between Deploys and Alerts, lit on the logs page" do
    sign_in_as users(:one)

    get logs_path

    assert_response :success
    labels = css_select("nav.side-nav a").map { |a| a.text.strip }
    assert_equal labels.index("发布") + 1, labels.index("日志")
    assert_equal labels.index("日志") + 1, labels.index("告警")
    assert_equal labels.index("告警") + 1, labels.index("审计")
    assert_select "nav.side-nav a.is-current", text: "日志"
  end

  test "without an app the page offers the apps the person may read logs of" do
    sign_in_as @developer

    get logs_path

    assert_select ".log-pick-list a", count: 1
    assert_select ".log-pick-list a[href=?]", logs_path(app: @blog.id)
    assert_select "select[name=app] option", text: "shop", count: 0
    assert_select "turbo-frame#log_results", count: 0
  end

  test "ops see every active app; deactivated ones are left out" do
    @shop.deactivate!
    sign_in_as users(:one)

    get logs_path

    assert_select ".log-pick-list a", count: 1
    assert_select ".log-pick-list a", text: "blog"
  end

  test "someone who may read no app's logs is told so" do
    AppMembership.delete_all
    sign_in_as @developer

    get logs_path

    assert_select ".empty-state", text: /没有你可以查看日志的应用/
  end

  test "another app's id is rejected on the page and on the results" do
    sign_in_as @developer

    get logs_path(app: @shop.id)
    assert_redirected_to root_path

    get logs_results_path(app: @shop.id)
    assert_redirected_to root_path
  end

  test "the conditions round-trip through the URL into the form and the results frame" do
    sign_in_as users(:two)

    # params:, not path options: `host:` would set the URL's host.
    get logs_path, params: { app: @blog.id, source: "app:worker", host: "127.0.0.1", since: "1h", lines: "500",
                             q: "boom & <b>", case: "1" }

    assert_response :success
    assert_select "select[name=app] option[selected][value=?]", @blog.id.to_s
    assert_select "select[name=source] option[selected][value=?]", "app:worker"
    assert_select "select[name=host] option[selected][value=?]", "127.0.0.1"
    assert_select "input[type=radio][name=since][value='1h'][checked]"
    assert_select "select[name=lines] option[selected][value='500']"
    assert_select "input[name=q][value=?]", "boom & <b>"
    assert_select "input[type=checkbox][name=case][checked]"

    frame_src = css_select("turbo-frame#log_results").first["src"]
    params = Rack::Utils.parse_query(URI(frame_src).query)
    assert_equal({ "app" => @blog.id.to_s, "source" => "app:worker", "host" => "127.0.0.1", "since" => "1h",
                   "lines" => "500", "q" => "boom & <b>", "case" => "1" }, params)
  end

  test "values that don't fit the app fall back to the defaults in the form" do
    sign_in_as users(:two)

    get logs_path, params: { app: @blog.id, source: "accessory:db", host: "10.9.9.9", since: "2d", lines: "7" }

    assert_select "select[name=source] option[selected][value='app']"
    assert_select "input[type=radio][name=since][value='15m'][checked]"
    assert_equal "#{logs_results_path}?app=#{@blog.id}", css_select("turbo-frame#log_results").first["src"]
  end

  test "results show per-host errors in the frame (no running container: no SSH at all)" do
    sign_in_as users(:one)

    get logs_results_path(app: @blog.id)

    assert_response :success
    assert_select "turbo-frame#log_results .log-errors li", text: /127\.0\.0\.1.*没有运行中的容器/m
    assert_select ".log-output .log-empty"
  end

  test "an app without an SSH key says so instead of trying every host" do
    sign_in_as users(:one)

    get logs_results_path(app: @shop.id)

    assert_select ".log-errors li", count: 1, text: /还没有配置 SSH 私钥/
  end

  test "invalid conditions on the results URL are refused" do
    sign_in_as users(:one)

    get logs_results_path(app: @blog.id, source: "app; reboot")

    assert_response :unprocessable_entity
    assert_select "turbo-frame#log_results .callout", text: /查询条件无效/
  end

  test "one query per user per 2 seconds, with a message in the frame" do
    sign_in_as users(:one)

    get logs_results_path(app: @blog.id)
    assert_response :success

    get logs_results_path(app: @blog.id)
    assert_response :too_many_requests
    assert_select "turbo-frame#log_results .callout", text: /查询太频繁/

    get logs_results_path(app: @blog.id, follow: "1", since: Time.current.iso8601)
    assert_response :too_many_requests
    assert_empty response.body

    travel 3.seconds do
      get logs_results_path(app: @blog.id)
      assert_response :success
    end
  end

  test "follow requests get a bare batch carrying the next cursor" do
    sign_in_as users(:one)
    since = 1.minute.ago.utc

    get logs_results_path(app: @blog.id, follow: "1", since: since.iso8601(9))

    assert_response :success
    assert_select "turbo-frame", count: 0
    assert_select "[data-log-batch][data-cursor=?]", since.iso8601(9)
  end

  test "the app page has a Logs tab with the same viewer, the app fixed" do
    sign_in_as @developer

    get managed_app_path(@blog, tab: "logs", since: "6h")

    assert_response :success
    assert_select "nav.tabs a.tab[aria-current=page]", text: "日志"
    assert_select "form.log-query[action=?]", managed_app_path(@blog)
    assert_select "form.log-query input[type=hidden][name=tab][value=logs]"
    assert_select "form.log-query select[name=app]", count: 0
    assert_select "input[type=radio][name=since][value='6h'][checked]"
    assert_select "turbo-frame#log_results[src=?]", logs_results_path(params: { app: @blog.id, since: "6h" })
  end

  test "the Logs tab is hidden from people who may not read the app's logs" do
    sign_in_as @developer

    get managed_app_path(@shop, tab: "logs")

    assert_select "nav.tabs a.tab", text: "日志", count: 0
    assert_select "nav.tabs a.tab[aria-current=page]", text: "概览"
    assert_select "turbo-frame#log_results", count: 0
  end

  test "the overview's view-logs button and the quick actions lead to the log pages" do
    sign_in_as users(:one)
    Observation.create!(managed_app: @blog, host: "127.0.0.1", role: "web", version: "aaa",
                        container_name: "blog-web-production-aaa", docker_status: "running",
                        reachable: true, observed_at: Time.current)

    get managed_app_path(@blog)
    assert_select "a[href=?]", managed_app_path(@blog, tab: "logs"), minimum: 1
    assert_select "form[action=?] input[name=name][value=logs]", managed_app_actions_path(@blog), count: 0

    get root_path
    assert_select ".app-card-foot a[href=?]", logs_path(app: @blog.id)
  end

  test "an app with an old version still on its hosts offers it; choosing it swaps follow for all-time" do
    now = Time.current
    { "blog-web-production-new1" => "running", "blog-web-production-old1" => "exited" }.each do |name, state|
      Observation.create!(managed_app: @blog, host: @blog.cached_app_hosts.first, role: "web", container_name: name,
                          version: name.split("-").last, docker_status: state, reachable: true, observed_at: now)
    end
    sign_in_as users(:one)

    get logs_path(app: @blog.id)
    assert_select "select[name=version] option", text: "当前运行中"
    assert_select "select[name=version] option[value=old1]", text: "old1（已停止）"
    assert_select "input[name=since][value=all]", count: 0
    assert_select "[data-log-viewer-target=followButton]"

    get logs_path(app: @blog.id, version: "old1")
    assert_select "select[name=version] option[selected][value=old1]"
    assert_select "input[name=since][value=all][checked]"
    assert_select "[data-log-viewer-target=followButton]", count: 0
    assert_select "turbo-frame#log_results[src*=?]", "version=old1"
  end
end

# The whole path with a real SSH round against the fake hosts: rows render escaped, with the
# keyword highlighted.
class LogsControllerFakeHostTest < ActionDispatch::IntegrationTest
  setup do
    FakeHost.ensure_ready!
    FakeHost.reset_all!
    Rails.cache.clear
    @managed_app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production",
                              ssh_credential: Credential.create!(kind: "ssh_key", name: "key", value: FakeHost.private_key))
    container = FakeHost.seed_container(node: "node-1", service: "blog", role: "web", destination: "production",
                                        version: "aaaaaaa",
                                        command: "echo '<script>alert(1)</script> Boom'; echo 'WARN quiet'; sleep 3600")
    sleep 1
    Observation.create!(managed_app: @managed_app, host: "127.0.0.1", role: "web", container_name: container,
                        docker_status: "running", version: "aaaaaaa", reachable: true, observed_at: Time.current)
  end

  test "renders the merged rows escaped, with levels and the keyword highlighted" do
    sign_in_as users(:two)

    get logs_results_path(app: @managed_app.id, q: "boom")

    assert_response :success
    assert_not_includes response.body, "<script>alert(1)</script>"
    assert_select ".log-row", count: 1
    assert_select ".log-row .log-host.log-host-0", text: "127.0.0.1"
    assert_select ".log-row .log-source", text: "web"
    assert_select ".log-row .log-line", text: "<script>alert(1)</script> Boom"
    assert_select ".log-row .log-line mark", text: "Boom"
    assert_select ".log-row time.log-time[datetime]"
    assert_select ".log-summary", text: /1 台主机 · 1 行/
  end
end
