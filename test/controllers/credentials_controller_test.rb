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
end
