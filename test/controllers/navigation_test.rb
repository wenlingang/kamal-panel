require "test_helper"

# The "current location" marker in the top navigation. It used to use current_page?(users_path),
# which is an exact match on the whole URL: as soon as you enter /users/new it no longer equals
# /users, the highlight disappears entirely, and on a subpage people can't tell which section
# they're in. Navigation must highlight by [section], not by page.
class NavigationTest < ActionDispatch::IntegrationTest
  setup do
    @managed_app = ManagedApp.create!(name: "blog",
                                      config_yaml: file_fixture("simple_deploy.yml").read,
                                      destination: "production")
    @credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    sign_in_as users(:two)
  end

  # Only assert "which section is lit", not how the class is spelled -- swapping the highlight
  # implementation shouldn't turn this red.
  def assert_current_nav(label, path)
    get path
    assert_response :success
    assert_select "nav.chrome-nav a.is-current", count: 1 do |links|
      assert_equal label, links.first.text.strip, "#{path} should highlight #{label}"
    end
  end

  test "highlights its own tab on each section's home page" do
    assert_current_nav "总览", root_path
    assert_current_nav "应用", managed_apps_path
    assert_current_nav "审计", audit_logs_path
    assert_current_nav "人员", users_path
    assert_current_nav "凭据", credentials_path
  end

  test "keeps the Apps tab highlighted on app sub-pages" do
    assert_current_nav "应用", new_managed_app_path
    assert_current_nav "应用", managed_app_path(@managed_app)
    assert_current_nav "应用", edit_managed_app_path(@managed_app)
  end

  test "keeps the Users tab highlighted on user sub-pages" do
    assert_current_nav "人员", new_user_path
    assert_current_nav "人员", edit_user_path(users(:one))
  end

  # Registry credentials are a different controller, but live under /credentials/registry, and to
  # the user they are things under the "Credentials" section.
  test "keeps the Credentials tab highlighted on credential sub-pages" do
    assert_current_nav "凭据", new_credential_path
    assert_current_nav "凭据", edit_credential_path(@credential)
    assert_current_nav "凭据", new_registry_credential_path
  end
end
