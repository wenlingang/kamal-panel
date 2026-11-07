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

  # The live-refresh controller morphs only these two regions; the filter bar sits outside both,
  # so a background update never touches a search box someone is typing in.
  test "marks the summary and the results as live regions, leaving the filter bar out" do
    app_with(name: "blog", versions: %w[aaaaaaa aaaaaaa])

    get overview_path

    assert_select "##{OverviewSignal::TARGET}[data-controller=live-refresh]" do
      assert_select "#overview-summary[data-live-refresh-target=region] .status-strip"
      assert_select "#overview-results[data-live-refresh-target=region] .app-card"
      assert_select "#overview-deactivated[data-live-refresh-target=region]"
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

  # Quick actions on the cards (spec §5). Rendering a card never SSHes: the restart version comes
  # from the observations, and the lock is left to RunActionJob.
  def restart_button_for(app)
    css_select("li.app-card").find { |card| card.at_css("h2 a")&.text == app.name }
                             &.at_css("form[action='#{managed_app_actions_path(app)}'] button")
  end
end
