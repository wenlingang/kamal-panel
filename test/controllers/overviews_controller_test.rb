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

    observed_at = Time.current # one collection round: every host shares its timestamp
    [ "10.0.0.1", "10.0.0.2" ].zip(versions).each do |host, version|
      Observation.create!(managed_app: app, host: host, role: "web",
                          container_name: "#{name}-web-production-#{version}",
                          version: version, docker_status: docker_status,
                          reachable: true, observed_at:)
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

  test "an app whose data is only stale is badged as stale, not as an unreachable host" do
    app = app_with(name: "blog", versions: %w[aaaaaaa aaaaaaa])
    Observation.where(managed_app: app).update_all(observed_at: 2.hours.ago)

    get overview_path

    assert_select ".app-card.status-unreachable .status-badge", text: I18n.t("statuses.stale")
    assert_select ".status-badge", text: I18n.t("statuses.unreachable"), count: 0
  end

  # The live-refresh controller morphs only these two regions; the filter bar sits outside both,
  # so a background update never touches a search box someone is typing in.
  test "marks the summary and the results as live regions, leaving the filter bar out" do
    app_with(name: "blog", versions: %w[aaaaaaa aaaaaaa])

    get overview_path

    assert_select "##{OverviewSignal::TARGET}[data-controller=live-refresh]" do
      assert_select "#overview-summary[data-live-refresh-target=region] .status-strip"
      assert_select "#overview-results[data-live-refresh-target=region] .app-card"
      assert_select "[data-live-refresh-target=region] form.filter-bar", count: 0
    end
  end

  test "lists all apps when there are no filter params" do
    app_with(name: "blog", versions: %w[aaaaaaa aaaaaaa])
    app_with(name: "shop", versions: %w[bbbbbbb ccccccc])

    get overview_path

    assert_response :success
    assert_select ".app-card-name", text: "blog"
    assert_select ".app-card-name", text: "shop"
  end

  test "fuzzy-matches by name" do
    app_with(name: "demo-blog", versions: %w[aaaaaaa aaaaaaa])
    app_with(name: "demo-shop", versions: %w[aaaaaaa aaaaaaa])

    get overview_path(q: "blo")

    assert_select ".app-card-name", text: "demo-blog"
    assert_select ".app-card-name", text: "demo-shop", count: 0
  end

  test "name matching is case-insensitive" do
    app_with(name: "Blog", versions: %w[aaaaaaa aaaaaaa])

    get overview_path(q: "blog")

    assert_select ".app-card-name", text: "Blog"
  end

  test "filters by status, keeping only healthy apps" do
    app_with(name: "healthy", versions: %w[aaaaaaa aaaaaaa])
    app_with(name: "drifted", versions: %w[aaaaaaa bbbbbbb])

    get overview_path(status: "ok")

    assert_select ".app-card-name", text: "healthy"
    assert_select ".app-card-name", text: "drifted", count: 0
  end

  test "filters by status, keeping only apps with version drift" do
    app_with(name: "healthy", versions: %w[aaaaaaa aaaaaaa])
    app_with(name: "drifted", versions: %w[aaaaaaa bbbbbbb])

    get overview_path(status: "drift")

    assert_select ".app-card-name", text: "drifted"
    assert_select ".app-card-name", text: "healthy", count: 0
  end

  # "Config can't be parsed" is not a level of ManagedAppStatus, but a separate row branch in the
  # grid. It is exactly the kind that most needs to be filtered out, so the dropdown must have it.
  test "filters by status, isolating apps whose config cannot be parsed" do
    broken_app(name: "unparseable")
    app_with(name: "healthy", versions: %w[aaaaaaa aaaaaaa])

    get overview_path(status: "parse_error")

    assert_select ".app-card-name", text: "unparseable"
    assert_select ".app-card-name", text: "healthy", count: 0
  end

  # An app whose config can't be parsed can't even have ManagedAppStatus computed (computing it
  # would blow up with ParseError again). When filtering by other statuses, it must neither leak
  # into the results nor crash the whole page.
  test "hides apps with unparseable config without error when filtering by another status" do
    broken_app(name: "unparseable")
    app_with(name: "healthy", versions: %w[aaaaaaa aaaaaaa])

    get overview_path(status: "ok")

    assert_response :success
    assert_select ".app-card-name", text: "healthy"
    assert_select ".app-card-name", text: "unparseable", count: 0
  end

  test "combines name and status filters" do
    app_with(name: "demo-blog", versions: %w[aaaaaaa bbbbbbb])
    app_with(name: "demo-shop", versions: %w[aaaaaaa bbbbbbb])
    app_with(name: "demo-api",  versions: %w[aaaaaaa aaaaaaa])

    get overview_path(q: "demo", status: "drift")

    assert_select ".app-card-name", text: "demo-blog"
    assert_select ".app-card-name", text: "demo-shop"
    assert_select ".app-card-name", text: "demo-api", count: 0
  end

  test "shows 'no matches' for an empty filter result, not 'no apps onboarded yet'" do
    app_with(name: "blog", versions: %w[aaaaaaa aaaaaaa])

    get overview_path(q: "不存在的应用")

    assert_response :success
    assert_select ".app-card, table.overview-grid", count: 0
    assert_select "p", text: /没有符合条件的应用/
    assert_select "a[href=?]", overview_path, text: /清除筛选/
  end

  test "shows the onboarding guide, not the filtered-empty state, when no apps are onboarded" do
    get overview_path

    assert_response :success
    assert_select "p", text: /这里还是空的/
  end

  # Params come from the URL, and anyone can edit them by hand. An unknown status value is treated
  # as no filter -- no 500, no empty page.
  test "treats an unknown status value as no filter" do
    app_with(name: "blog", versions: %w[aaaaaaa aaaaaaa])

    get overview_path(status: "不是一个状态")

    assert_response :success
    assert_select ".app-card-name", text: "blog"
  end

  # Filtering means "I only want to see these rows right now", not "the rest needn't be collected".
  # Following the filter would let people silently slow down collection for other apps just by
  # filtering, and that is the last thing that should happen during an incident.
  test "filtering does not affect polling cadence; filtered-out apps are still marked as being viewed" do
    visible = app_with(name: "blog", versions: %w[aaaaaaa aaaaaaa])
    hidden  = app_with(name: "shop", versions: %w[aaaaaaa aaaaaaa])

    get overview_path(q: "blog")

    assert_equal PollCadence::VIEWING, PollCadence.interval_for(visible)
    assert_equal PollCadence::VIEWING, PollCadence.interval_for(hidden)
  end

  test "refills the filter form with the current criteria" do
    app_with(name: "blog", versions: %w[aaaaaaa aaaaaaa])

    get overview_path(q: "blo", status: "ok")

    assert_select "input[name=q][value=?]", "blo"
    assert_select "select[name=status] option[selected][value=?]", "ok"
  end

  test "the list view keeps the table, with the same filters" do
    app_with(name: "blog", versions: %w[aaaaaaa aaaaaaa])
    app_with(name: "shop", versions: %w[bbbbbbb ccccccc])

    get overview_path(view: "table", status: "drift")

    assert_select "table.overview-grid td", text: "shop"
    assert_select "table.overview-grid td", text: "blog", count: 0
    assert_select ".app-card", count: 0
    # Filtering again from the list view stays in the list view.
    assert_select "form.filter-bar input[type=hidden][name=view][value=table]"
  end

  test "the summary strip counts every app by status, each count linking to its filter" do
    app_with(name: "blog", versions: %w[aaaaaaa aaaaaaa])
    app_with(name: "shop", versions: %w[bbbbbbb ccccccc])
    app_with(name: "wiki", versions: %w[ddddddd ddddddd])

    # Counts cover the whole fleet even while the grid is filtered.
    get overview_path(q: "blog")

    assert_select ".status-strip a.strip-ok[href=?] .strip-count", overview_path(q: "blog", status: "ok"), text: "2"
    assert_select ".status-strip a.strip-drift .strip-count", text: "1"
    assert_select ".status-strip a.strip-all .strip-count", text: "3"
  end

  test "the summary strip marks the active status filter" do
    app_with(name: "blog", versions: %w[aaaaaaa aaaaaaa])

    get overview_path(status: "ok")

    assert_select ".status-strip a[aria-current]", count: 1
    assert_select ".status-strip a.strip-ok[aria-current]"
  end

  test "the summary strip shows the parse-error count only when there is one" do
    app_with(name: "blog", versions: %w[aaaaaaa aaaaaaa])

    get overview_path
    assert_select ".status-strip a[href*=?]", "status=parse_error", count: 0

    broken_app(name: "broken")
    get overview_path
    assert_select ".status-strip a[href*=?] .strip-count", "status=parse_error", text: "1"
  end

  test "each card carries a heartbeat strip of the recent rounds" do
    app_with(name: "blog", versions: %w[aaaaaaa aaaaaaa])

    get overview_path

    assert_select ".app-card .heartbeat .hb-cell", StatusHistory::DEFAULT_ROUNDS
    assert_select ".app-card .heartbeat .hb-ok", 1
    assert_select ".app-card .heartbeat-cells[role=img][aria-label]"
  end

  test "a card for an app whose config cannot be parsed still renders, heartbeat included" do
    broken_app(name: "broken")

    get overview_path

    assert_response :success
    assert_select ".app-card .status-badge", text: I18n.t("overviews.grid.config_broken")
    assert_select ".app-card .heartbeat"
  end

  # Quick actions on the cards (spec §5). Rendering a card never SSHes: the restart version comes
  # from the observations, and the lock is left to RunActionJob.
  def restart_button_for(app)
    css_select("li.app-card").find { |card| card.at_css("h2 a")&.text == app.name }
                             &.at_css("form[action='#{managed_app_actions_path(app)}'] button")
  end

  test "a member sees an enabled restart with the running version and a link to the actions tab" do
    app = app_with(name: "blog", versions: %w[abc1234 abc1234])
    app.update!(ssh_credential: Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "key"))
    sign_in_as users(:two)

    get overview_path

    button = restart_button_for(app)
    assert button, "the card offers a restart"
    refute button.has_attribute?("disabled")
    assert_select "li.app-card form[action=?] input[name=version][value=abc1234]", managed_app_actions_path(app)
    assert_select "li.app-card form[action=?][data-turbo-confirm]", managed_app_actions_path(app)
    assert_select "li.app-card a[href=?]", managed_app_path(app, tab: "actions")
  end

  test "restart stays on the card but disabled, with the reason, when the running version is unknown" do
    app = app_with(name: "blog", versions: %w[abc1234 def5678])
    app.update!(ssh_credential: Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "key"))
    sign_in_as users(:two)

    get overview_path

    button = restart_button_for(app)
    assert button.has_attribute?("disabled")
    assert_equal I18n.t("quick_actions.restart_unavailable"), button["title"]
  end

  test "restart is disabled with a reason when the app has no SSH key" do
    app = app_with(name: "blog", versions: %w[abc1234 abc1234])
    sign_in_as users(:two)

    get overview_path

    assert_equal I18n.t("quick_actions.restart_no_key"), restart_button_for(app)["title"]
  end

  test "someone who can't act on the app gets no restart on its card" do
    app = app_with(name: "blog", versions: %w[abc1234 abc1234])

    get overview_path # signed in as ops

    assert_nil restart_button_for(app)
  end
end
