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
end
