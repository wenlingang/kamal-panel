require "test_helper"

class CredentialsControllerTest < ActionDispatch::IntegrationTest
  # Note: in this file [don't] store the ManagedApp in @app -- in
  # ActionDispatch::IntegrationTest, @app overrides Runner#app, every *_path
  # helper disappears, and the error looks like routes aren't defined.
  setup do
    @managed_app = ManagedApp.create!(name: "blog",
                                      config_yaml: file_fixture("simple_deploy.yml").read,
                                      destination: "production")
  end

  # Rotation must swap in [a different] key to prove anything: replacing a key with itself means the
  # assertion goes green even if update wrote nothing. Generate once and reuse across the whole file
  # -- generating a 2048-bit key isn't cheap.
  def self.other_private_key
    @other_private_key ||= OpenSSL::PKey::RSA.generate(2048).to_pem
  end

  def other_private_key = self.class.other_private_key

  # When asserting "the plaintext changed", compare digests rather than plaintext: when an assertion
  # fails minitest prints both sides, and comparing plaintext would dump the private key into the
  # test output.
  def value_digest(record) = Digest::SHA256.hexdigest(record.value)

  test "denies non-admins every action" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    digest_before = value_digest(credential)

    [ users(:one), users(:three) ].each do |user|
      sign_in_as user

      get credentials_path
      assert_redirected_to root_path

      get new_credential_path
      assert_redirected_to root_path

      assert_no_difference -> { Credential.count } do
        post credentials_path, params: { credential: { name: "偷渡", value: FakeHost.private_key } }
      end
      assert_redirected_to root_path

      get edit_credential_path(credential)
      assert_redirected_to root_path

      patch credential_path(credential), params: { credential: { value: other_private_key } }
      assert_redirected_to root_path
      assert_equal digest_before, value_digest(credential.reload)

      assert_no_difference -> { Credential.count } do
        delete credential_path(credential)
      end
      assert_redirected_to root_path

      sign_out
    end
  end

  test "lets admin see the list and which apps reference each credential" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    @managed_app.update!(ssh_credential: credential)
    sign_in_as users(:two)

    get credentials_path

    assert_response :success
    assert_select "td", text: /生产集群/
    assert_select "td", text: /blog/
  end

  # Credentials are write-only. These three guard the same thing: the form page must [never] render
  # the private key plaintext back into HTML. Remove `value: nil` from the view and these three go
  # red -- form.text_area by default renders the persisted record's current value as the tag body.
  test "keeps the private key plaintext out of the index page" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    @managed_app.update!(ssh_credential: credential)
    sign_in_as users(:two)

    get credentials_path

    assert_response :success
    refute_includes @response.body, FakeHost.private_key
  end

  test "does not echo the private key plaintext on the new or replace pages" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    sign_in_as users(:two)

    get new_credential_path
    assert_response :success
    refute_includes @response.body, FakeHost.private_key

    get edit_credential_path(credential)
    assert_response :success
    refute_includes @response.body, FakeHost.private_key
  end

  test "does not echo the private key plaintext when re-rendering the form after a failed create" do
    Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    sign_in_as users(:two)

    # Duplicate name, so creation must fail and take the render :new re-render path.
    post credentials_path, params: { credential: { name: "生产集群", value: FakeHost.private_key } }

    assert_response :unprocessable_entity
    refute_includes @response.body, FakeHost.private_key
  end

  test "writes an audit log on create that records which credential it was" do
    sign_in_as users(:two)

    assert_difference -> { Credential.count }, 1 do
      post credentials_path, params: { credential: { name: "生产集群", value: FakeHost.private_key } }
    end

    log = AuditLog.where(action_name: "credential.create").sole
    assert_equal "生产集群", log.detail
    assert_nil log.managed_app
  end

  test "rotation replaces the value, keeps the name, and writes an audit log" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    digest_before = value_digest(credential)
    sign_in_as users(:two)

    patch credential_path(credential), params: { credential: { value: other_private_key } }

    credential.reload
    assert_equal "生产集群", credential.name
    refute_equal digest_before, value_digest(credential)
    assert_equal 1, AuditLog.where(action_name: "credential.rotate").count
  end

  test "refuses to delete a referenced credential and shows the reason" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    @managed_app.update!(ssh_credential: credential)
    sign_in_as users(:two)

    delete credential_path(credential)

    assert_redirected_to credentials_path
    # This sentence is the only thing on this path that tells people "which apps to go change next",
    # so it must name that app.
    assert_includes flash[:alert], "生产集群"
    assert_includes flash[:alert], "blog"
    # The panel has no entry point for changing credentials on an already-onboarded app
    # (managed_apps has no update in routes), so this hint can only point to "replace this
    # credential's content", the path that actually works.
    assert_includes flash[:alert], edit_credential_path(credential)
    refute_includes flash[:alert], "换成别的凭据"
    assert Credential.exists?(credential.id)
    assert_equal 0, AuditLog.where(action_name: "credential.delete").count
  end

  test "deletes an unreferenced credential and writes an audit log" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "闲置的")
    sign_in_as users(:two)

    delete credential_path(credential)

    refute Credential.exists?(credential.id)
    assert_equal "闲置的", AuditLog.where(action_name: "credential.delete").sole.detail
  end
end
