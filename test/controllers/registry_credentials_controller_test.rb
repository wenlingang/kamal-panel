require "test_helper"

class RegistryCredentialsControllerTest < ActionDispatch::IntegrationTest
  # An easily recognizable literal: seeing it in HTML makes a leak obvious at a glance, and it won't
  # collide with other bytes.
  SECRET = "绝密registry密码-Zk7q".freeze
  OTHER_SECRET = "另一个绝密registry密码-Mx2v".freeze

  test "non-admins cannot access any action" do
    credential = RegistryCredential.create!(name: "Docker Hub", value: SECRET,
                                            server: "registry.example.com")
    sign_in_as users(:three)

    get new_registry_credential_path
    assert_redirected_to root_path

    assert_no_difference -> { RegistryCredential.count } do
      post registry_credentials_path, params: { registry_credential: { name: "偷渡", value: "x" } }
    end
    assert_redirected_to root_path

    get edit_registry_credential_path(credential)
    assert_redirected_to root_path

    patch registry_credential_path(credential),
          params: { registry_credential: { value: OTHER_SECRET } }
    assert_redirected_to root_path
    assert_equal SECRET, credential.reload.value

    assert_no_difference -> { RegistryCredential.count } do
      delete registry_credential_path(credential)
    end
    assert_redirected_to root_path
  end

  test "admin creates a credential and an audit entry is written" do
    sign_in_as users(:two)

    assert_difference -> { RegistryCredential.count }, 1 do
      post registry_credentials_path,
           params: { registry_credential: { name: "Docker Hub", value: "s3cr3t", server: "registry.example.com" } }
    end

    assert_equal "Docker Hub", AuditLog.where(action_name: "registry_credential.create").sole.detail
  end

  # Credentials are write-only: the form page must never render the password plaintext back into
  # HTML.
  test "neither the new page nor the replace page echoes the password in plaintext" do
    credential = RegistryCredential.create!(name: "Docker Hub", value: SECRET,
                                            server: "registry.example.com")
    sign_in_as users(:two)

    get new_registry_credential_path
    assert_response :success
    refute_includes @response.body, SECRET

    get edit_registry_credential_path(credential)
    assert_response :success
    refute_includes @response.body, SECRET
  end

  test "the re-rendered form after a failed create does not echo the password in plaintext either" do
    RegistryCredential.create!(name: "Docker Hub", value: SECRET)
    sign_in_as users(:two)

    # Duplicate name, so creation must fail and take the render :new re-render path.
    post registry_credentials_path,
         params: { registry_credential: { name: "Docker Hub", value: SECRET } }

    assert_response :unprocessable_entity
    refute_includes @response.body, SECRET
  end

  test "the list page does not contain the password in plaintext" do
    RegistryCredential.create!(name: "Docker Hub", value: SECRET, server: "registry.example.com")
    sign_in_as users(:two)

    get credentials_path

    assert_response :success
    refute_includes @response.body, SECRET
  end

  def value_digest(record) = Digest::SHA256.hexdigest(record.value)

  test "rotation really replaces the value, keeps the name, and writes an audit entry" do
    credential = RegistryCredential.create!(name: "Docker Hub", value: SECRET,
                                            server: "registry.example.com")
    digest_before = value_digest(credential)
    sign_in_as users(:two)

    patch registry_credential_path(credential),
          params: { registry_credential: { value: OTHER_SECRET } }

    credential.reload
    assert_equal "Docker Hub", credential.name
    refute_equal digest_before, value_digest(credential)
    assert_equal "Docker Hub", AuditLog.where(action_name: "registry_credential.rotate").sole.detail
  end

  test "an unreferenced credential can be deleted and an audit entry is written" do
    credential = RegistryCredential.create!(name: "闲置的", value: SECRET)
    sign_in_as users(:two)

    delete registry_credential_path(credential)

    refute RegistryCredential.exists?(credential.id)
    assert_equal "闲置的", AuditLog.where(action_name: "registry_credential.delete").sole.detail
  end

  # When referenced, that hint is the only copy on this page that teaches people what to do, so what
  # it says must be something the panel can really do: the panel has no entry point for changing
  # credentials on an onboarded app; all it can do is replace this credential's content.
  test "a referenced credential cannot be deleted and the hint names the app and only suggests feasible actions" do
    credential = RegistryCredential.create!(name: "Docker Hub", value: SECRET)
    ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                       destination: "production", registry_credential: credential)
    sign_in_as users(:two)

    delete registry_credential_path(credential)

    assert_redirected_to credentials_path
    assert_includes flash[:alert], "Docker Hub"
    assert_includes flash[:alert], "blog"
    assert_includes flash[:alert], edit_registry_credential_path(credential)
    refute_includes flash[:alert], "换成别的凭据"
    assert RegistryCredential.exists?(credential.id)
    assert_equal 0, AuditLog.where(action_name: "registry_credential.delete").count
  end
end
