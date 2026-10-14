require "test_helper"

class LocksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @managed_app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                                      destination: "production")
  end

  # Without a key the lock can't be read; the old wording blamed the network ("cannot reach the
  # primary host"), which sent people to debug the wrong thing.
  test "an app without an SSH key says so, and points someone who can fix it to the edit page" do
    sign_in_as users(:two) # admin

    get managed_app_lock_path(@managed_app)

    assert_match I18n.t("managed_apps.show.no_ssh_key"), @response.body
    assert_no_match I18n.t("managed_apps.show.lock_unknown_detail"), @response.body
    assert_select "a[href=?]", edit_managed_app_path(@managed_app)
  end

  test "someone who can't edit the app gets the reason but no edit link" do
    sign_in_as users(:one) # ops: sees every app, but editing an app is admin-only

    get managed_app_lock_path(@managed_app)

    assert_match I18n.t("managed_apps.show.no_ssh_key"), @response.body
    assert_select "a[href=?]", edit_managed_app_path(@managed_app), count: 0
  end

  test "the detail page keeps the actions section in place while the lock loads" do
    sign_in_as users(:two)

    get managed_app_path(@managed_app)

    assert_select "section.actions h2", text: I18n.t("managed_apps.show.actions")
    assert_select "section.actions turbo-frame#lock_and_actions"
  end
end
