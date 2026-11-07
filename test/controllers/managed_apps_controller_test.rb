require "test_helper"

class ManagedAppsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(users(:two)) } # admin: onboarding an app is a write operation

  def valid_yaml
    file_fixture("simple_deploy.yml").read
  end

  def valid_key
    File.read(Rails.root.join("test/fake_host/id_ed25519"))
  end

  test "does not let ops onboard apps" do
    sign_in_as(users(:one)) # ops

    assert_no_difference "ManagedApp.count" do
      post managed_apps_path, params: {
        managed_app: { name: "blog", config_yaml: valid_yaml }
      }
    end

    assert_redirected_to root_path
  end

  # ---- Editing apps (branch app-edit) -------------------------------------------
  #
  # Before this, an app was permanently immutable once onboarded: no update, no destroy. After
  # credentials went into a shared pool this became a real flaw -- a referenced credential can't be
  # deleted, and "first switch the app to another credential" can't be done in the panel at all.

  def editable_app(**attrs)
    ManagedApp.create!({ name: "blog", config_yaml: valid_yaml, destination: "production" }.merge(attrs))
  end

  test "does not let a non-owning developer edit another app" do
    app = editable_app
    sign_in_as users(:three)

    patch managed_app_path(app), params: { managed_app: { name: "被别人改了" } }

    assert_equal "blog", app.reload.name
  end

  # Rebinding a credential is in effect "which private key to hand to this app", and credentials are
  # managed by admin alone. Hiding the dropdown in the view only saves one doomed click; the real
  # defense must be at the params layer, otherwise a hand-crafted PATCH would let a developer swap
  # their app onto any key in the pool.
  test "drops a developer's forged credential id params at the parameter layer" do
    credential = Credential.create!(kind: "ssh_key", value: valid_key, name: "别人的钥匙")
    app = editable_app
    AppMembership.create!(user: users(:three), managed_app: app)
    sign_in_as users(:three)

    patch managed_app_path(app), params: {
      managed_app: { name: "blog-renamed", ssh_credential_id: credential.id }
    }

    assert_equal "blog-renamed", app.reload.name, "the fields it may edit itself should still take effect"
    assert_nil app.ssh_credential, "the credential binding must not be changed by a non-admin"
  end

  # ---- Deactivating and activating (branch app-deactivate) ------------------------------------
end
