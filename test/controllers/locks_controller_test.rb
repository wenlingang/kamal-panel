require "test_helper"

class LocksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @managed_app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("accessory_deploy.yml").read,
                                      destination: "production")
    # A running version, so restart is usable unless something else blocks it.
    %w[10.0.0.1 10.0.0.2].each do |host|
      Observation.create!(managed_app: @managed_app, host: host, role: "web",
                          container_name: "blog-web-production-abc1234", version: "abc1234",
                          docker_status: "running", reachable: true, observed_at: Time.current)
    end
  end

  def give_ssh_key
    @managed_app.update!(ssh_credential: Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "key"))
  end

  # KamalLock reads over SSH; these tests are about what the panel renders for each answer.
  def with_lock_status(status)
    original = KamalLock.instance_method(:status)
    KamalLock.define_method(:status) { status }
    yield
  ensure
    KamalLock.define_method(:status, original)
  end

  def panel_text(key) = I18n.t("managed_apps.actions_panel.#{key}")

  def assert_buttons_render
    assert_select "#action-group-app input[type=submit][value=?]", I18n.t("managed_apps.actions_panel.app.restart")
    assert_select "#action-group-app button", text: I18n.t("managed_apps.actions_panel.app.start")
    assert_select "#action-group-app button", text: I18n.t("managed_apps.actions_panel.app.live")
    assert_select "#action-group-app details.confirm-action input[name=name][value=stop]"
    assert_select "#action-group-app details.confirm-action input[name=name][value=maintenance]"
    assert_select "#action-group-accessories tr#accessory-db button", text: I18n.t("managed_apps.actions_panel.accessories.restart")
    assert_select "#action-group-accessories tr#accessory-cache input[name=name][value=accessory_reboot]"
    assert_select "#action-group-proxy input[name=name][value=proxy_restart]"
    assert_select "#action-group-housekeeping button", text: I18n.t("managed_apps.actions_panel.housekeeping.prune")
  end

  test "lock free: every button renders and is enabled" do
    give_ssh_key
    sign_in_as users(:two)

    with_lock_status({ locked: false, details: nil, error: nil }) { get managed_app_lock_path(@managed_app) }

    assert_buttons_render
    assert_select "button[disabled], fieldset[disabled]", count: 0
    assert_match panel_text("lock.free"), @response.body
  end

  test "locked: mutating buttons are disabled, the holder is shown, force unlock is offered" do
    give_ssh_key
    sign_in_as users(:two)

    with_lock_status({ locked: true, details: "Locked by: ci@example.com", error: nil }) do
      get managed_app_lock_path(@managed_app)
    end

    assert_buttons_render
    assert_match panel_text("lock.held"), @response.body
    assert_match "Locked by: ci@example.com", @response.body
    assert_select "button[disabled]", text: I18n.t("managed_apps.actions_panel.app.start")
    assert_select "#action-group-app fieldset[disabled] input[value=?]", I18n.t("managed_apps.actions_panel.app.restart")
    assert_select "#action-group-proxy fieldset[disabled]"
    assert_select ".lock-held input[name=name][value=force_unlock]"
    assert_select ".lock-held fieldset[disabled]", count: 0
  end

  test "lock unreadable: buttons stay enabled and the page says the lock is checked again before running" do
    give_ssh_key
    sign_in_as users(:two)

    with_lock_status({ locked: false, details: nil, error: "connection refused" }) do
      get managed_app_lock_path(@managed_app)
    end

    assert_buttons_render
    assert_select "button[disabled], fieldset[disabled]", count: 0
    assert_match panel_text("lock.unknown_detail"), @response.body
  end

  # Without a key the lock can't be read; the old wording blamed the network ("cannot reach the
  # primary host"), which sent people to debug the wrong thing.
  test "no SSH key: buttons render disabled, and someone who can fix it gets the edit link" do
    sign_in_as users(:two) # admin

    get managed_app_lock_path(@managed_app)

    assert_buttons_render
    assert_match panel_text("lock.no_key"), @response.body
    assert_select "button[disabled]", text: I18n.t("managed_apps.actions_panel.app.start")
    assert_select "a[href=?]", edit_managed_app_path(@managed_app)
  end

  test "no SSH key, someone who can't edit the app gets the reason but no edit link" do
    sign_in_as users(:one) # ops: sees every app, but editing an app is admin-only

    get managed_app_lock_path(@managed_app)

    assert_match panel_text("lock.no_key"), @response.body
    assert_match panel_text("lock.no_key_ask"), @response.body
    assert_select "a[href=?]", edit_managed_app_path(@managed_app), count: 0
  end

  test "no permission: the panel is read-only, not hidden" do
    give_ssh_key
    sign_in_as users(:three) # developer, not a member

    with_lock_status({ locked: false, details: nil, error: nil }) { get managed_app_lock_path(@managed_app) }

    assert_buttons_render
    assert_match panel_text("no_permission"), @response.body
    assert_select "button[disabled]", text: I18n.t("managed_apps.actions_panel.app.start")
    assert_select "button:not([disabled])", count: 0
  end

  test "restart without a known running version stays visible, disabled, with the reason" do
    Observation.where(managed_app: @managed_app).delete_all
    give_ssh_key
    sign_in_as users(:two)

    with_lock_status({ locked: false, details: nil, error: nil }) { get managed_app_lock_path(@managed_app) }

    assert_select "#action-group-app fieldset[disabled] input[value=?]", I18n.t("managed_apps.actions_panel.app.restart")
    assert_match I18n.t("managed_apps.actions_panel.app.restart_unavailable"), @response.body
  end

  test "restart offers each app host; accessories list their image and hosts" do
    give_ssh_key
    sign_in_as users(:two)

    with_lock_status({ locked: false, details: nil, error: nil }) { get managed_app_lock_path(@managed_app) }

    assert_select "select[name=target] option[value='10.0.0.1']"
    assert_select "select[name=target] option[value='10.0.0.3']", count: 0
    assert_select "tr#accessory-db td", text: "postgres:16"
    assert_select "tr#accessory-db td", text: "10.0.0.3"
  end

  test "the detail page renders the buttons right away while the lock loads" do
    give_ssh_key
    sign_in_as users(:two)

    get managed_app_path(@managed_app, tab: "actions")

    assert_select "section.actions h2", text: I18n.t("managed_apps.show.actions")
    assert_select "section.actions turbo-frame#lock_and_actions[src=?][target=_top]", managed_app_lock_path(@managed_app)
    assert_buttons_render
    assert_match panel_text("lock.reading"), @response.body
    assert_select "button[disabled], fieldset[disabled]", count: 0
  end

  test "without an SSH key the detail page doesn't ask for the lock at all" do
    sign_in_as users(:two)

    get managed_app_path(@managed_app, tab: "actions")

    assert_select "turbo-frame#lock_and_actions:not([src])"
    assert_match panel_text("lock.no_key"), @response.body
  end

  # Reading the lock means SSH; only the tab that shows it should pay for that.
  test "the detail page's other tabs do not start reading the lock" do
    sign_in_as users(:two)

    get managed_app_path(@managed_app)

    assert_select "turbo-frame#lock_and_actions", count: 0
  end
end
