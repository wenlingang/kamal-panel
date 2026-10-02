require "test_helper"

class OverviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear # cached_app_hosts 缓存键含 id，SQLite 回滚后可能复用 id

    # 只看总览是 ops 就能做的事，不需要 admin。
    sign_in_as users(:one)
  end

  # 状态这一维不是数据库列，是 ManagedAppStatus 现算出来的。所以这些测试
  # 不能直接塞一个 status 字段，只能把观测造成"会算出那个状态"的样子。
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

  # 「配置无法解析」不是 ManagedAppStatus 的一档 level，而是网格里另一条
  # 独立的行分支。它恰恰是最该被筛出来的一类，所以下拉里必须有它。
  test "按状态筛选——配置无法解析的应用能被单独筛出来" do
    broken_app(name: "unparseable")
    app_with(name: "healthy", versions: %w[aaaaaaa aaaaaaa])

    get overview_path(status: "parse_error")

    assert_select "table.overview-grid td", text: "unparseable"
    assert_select "table.overview-grid td", text: "healthy", count: 0
  end

  # 配置解析不了的应用连 ManagedAppStatus 都算不出来（一算就再炸一次
  # ParseError）。按别的状态筛选时，它既不能混进结果，更不能把整页搞崩。
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

  # 参数是从 URL 来的，谁都能手改。未知的状态值当作没筛，不 500 也不给空页。
  test "未知的状态值当作没有筛选" do
    app_with(name: "blog", versions: %w[aaaaaaa aaaaaaa])

    get overview_path(status: "不是一个状态")

    assert_response :success
    assert_select "table.overview-grid td", text: "blog"
  end

  # 筛选是"我现在只想看这几行"，不是"其余的不用采了"。跟着筛选走会让人
  # 一筛就把其他应用的采集悄悄降速，而那恰恰是出问题时最不该发生的事。
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
