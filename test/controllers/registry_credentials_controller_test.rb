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

  def value_digest(record) = Digest::SHA256.hexdigest(record.value)
end
