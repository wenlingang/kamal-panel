require "test_helper"

class OverviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear # cached_app_hosts cache key contains the id, and SQLite may reuse ids after rollback

    # Viewing the overview is something ops can do; admin isn't needed.
    sign_in_as users(:one)
  end

  # Status is not a database column; it's computed on the fly by ManagedAppStatus. So these tests
  # can't just stuff in a status field; they can only shape observations so they "compute to that
  # status".
  def app_with(name:, versions:, docker_status: "running")
    app = ManagedApp.create!(name: name,
                             config_yaml: file_fixture("two_host_deploy.yml").read,
                             destination: "production")

    [ "10.0.0.1", "10.0.0.2" ].zip(versions).each do |host, version|
      Observation.create!(managed_app: app, host: host, role: "web",
                          container_name: "#{name}-web-production-#{version}",
                          version: version, docker_status: docker_status,
                          reachable: true, observed_at: Time.current)
    end

    app
  end

  def broken_app(name:)
    app = ManagedApp.create!(name: name,
                             config_yaml: file_fixture("simple_deploy.yml").read,
                             destination: "production")
    app.update_columns(last_poll_error: "mapping values are not allowed here",
                       last_poll_error_at: Time.current,
                       first_poll_error_at: Time.current)
    app
  end

  test "没有筛选参数时列出全部应用" do
    app_with(name: "blog", versions: %w[aaaaaaa aaaaaaa])
    app_with(name: "shop", versions: %w[bbbbbbb ccccccc])

    get overview_path

    assert_response :success
    assert_select "table.overview-grid td", text: "blog"
    assert_select "table.overview-grid td", text: "shop"
  end

  test "按名称模糊匹配" do
    app_with(name: "demo-blog", versions: %w[aaaaaaa aaaaaaa])
    app_with(name: "demo-shop", versions: %w[aaaaaaa aaaaaaa])

    get overview_path(q: "blo")

    assert_select "table.overview-grid td", text: "demo-blog"
    assert_select "table.overview-grid td", text: "demo-shop", count: 0
  end

  test "名称匹配不分大小写" do
    app_with(name: "Blog", versions: %w[aaaaaaa aaaaaaa])

    get overview_path(q: "blog")

    assert_select "table.overview-grid td", text: "Blog"
  end

  test "按状态筛选——只留正常的" do
    app_with(name: "healthy", versions: %w[aaaaaaa aaaaaaa])
    app_with(name: "drifted", versions: %w[aaaaaaa bbbbbbb])

    get overview_path(status: "ok")

    assert_select "table.overview-grid td", text: "healthy"
    assert_select "table.overview-grid td", text: "drifted", count: 0
  end

  test "按状态筛选——只留版本不一致的" do
    app_with(name: "healthy", versions: %w[aaaaaaa aaaaaaa])
    app_with(name: "drifted", versions: %w[aaaaaaa bbbbbbb])

    get overview_path(status: "drift")

    assert_select "table.overview-grid td", text: "drifted"
    assert_select "table.overview-grid td", text: "healthy", count: 0
  end

  # "Config can't be parsed" is not a level of ManagedAppStatus, but a separate row branch in the
  # grid. It is exactly the kind that most needs to be filtered out, so the dropdown must have it.
  test "按状态筛选——配置无法解析的应用能被单独筛出来" do
    broken_app(name: "unparseable")
    app_with(name: "healthy", versions: %w[aaaaaaa aaaaaaa])

    get overview_path(status: "parse_error")

    assert_select "table.overview-grid td", text: "unparseable"
    assert_select "table.overview-grid td", text: "healthy", count: 0
  end

  # An app whose config can't be parsed can't even have ManagedAppStatus computed (computing it
  # would blow up with ParseError again). When filtering by other statuses, it must neither leak
  # into the results nor crash the whole page.
  test "按别的状态筛选时，配置无法解析的应用不出现也不报错" do
    broken_app(name: "unparseable")
    app_with(name: "healthy", versions: %w[aaaaaaa aaaaaaa])

    get overview_path(status: "ok")

    assert_response :success
    assert_select "table.overview-grid td", text: "healthy"
    assert_select "table.overview-grid td", text: "unparseable", count: 0
  end

  test "名称与状态叠加" do
    app_with(name: "demo-blog", versions: %w[aaaaaaa bbbbbbb])
    app_with(name: "demo-shop", versions: %w[aaaaaaa bbbbbbb])
    app_with(name: "demo-api",  versions: %w[aaaaaaa aaaaaaa])

    get overview_path(q: "demo", status: "drift")

    assert_select "table.overview-grid td", text: "demo-blog"
    assert_select "table.overview-grid td", text: "demo-shop"
    assert_select "table.overview-grid td", text: "demo-api", count: 0
  end

  test "筛空了给的是「没有符合条件」，不是「一个应用都还没接入」" do
    app_with(name: "blog", versions: %w[aaaaaaa aaaaaaa])

    get overview_path(q: "不存在的应用")

    assert_response :success
    assert_select "table.overview-grid", count: 0
    assert_select "p", text: /没有符合条件的应用/
    assert_select "a[href=?]", overview_path, text: /清除筛选/
  end

  test "一个应用都没接入时，给的仍是接入引导而不是筛选空状态" do
    get overview_path

    assert_response :success
    assert_select "p", text: /这里还是空的/
  end

  # Params come from the URL, and anyone can edit them by hand. An unknown status value is treated
  # as no filter -- no 500, no empty page.
  test "未知的状态值当作没有筛选" do
    app_with(name: "blog", versions: %w[aaaaaaa aaaaaaa])

    get overview_path(status: "不是一个状态")

    assert_response :success
    assert_select "table.overview-grid td", text: "blog"
  end

  # Filtering means "I only want to see these rows right now", not "the rest needn't be collected".
  # Following the filter would let people silently slow down collection for other apps just by
  # filtering, and that is the last thing that should happen during an incident.
  test "筛选不影响采集节奏——被筛掉的应用一样标记为正在被查看" do
    visible = app_with(name: "blog", versions: %w[aaaaaaa aaaaaaa])
    hidden  = app_with(name: "shop", versions: %w[aaaaaaa aaaaaaa])

    get overview_path(q: "blog")

    assert_equal PollCadence::VIEWING, PollCadence.interval_for(visible)
    assert_equal PollCadence::VIEWING, PollCadence.interval_for(hidden)
  end

  test "筛选条件回填到表单里" do
    app_with(name: "blog", versions: %w[aaaaaaa aaaaaaa])

    get overview_path(q: "blo", status: "ok")

    assert_select "input[name=q][value=?]", "blo"
    assert_select "select[name=status] option[selected][value=?]", "ok"
  end
end
