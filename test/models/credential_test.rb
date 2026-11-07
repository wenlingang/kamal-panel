require "test_helper"

class CredentialTest < ActiveSupport::TestCase
  def key
    File.read(Rails.root.join("test/fake_host/id_ed25519"))
  end

  test "stores the private key encrypted in the database" do
    credential = Credential.create!(kind: "ssh_key", value: key, name: "私钥在数据库中是密文")

    raw = Credential.connection.select_value(
      "SELECT value FROM credentials WHERE id = #{credential.id}"
    )

    refute_includes raw.to_s, "PRIVATE KEY"
    assert_equal key, credential.reload.value
  end

  # --- The tests below treat "validating a submitted private key" as an attack rather
  # than the happy path: value is currently validated on an unauthenticated route
  # (creating a ManagedApp doesn't require login), so the submitter can be anyone and the
  # bytes can be carefully crafted. Attack-surface tests for net-ssh's parsing behavior
  # itself (malformed encodings, huge KDF parameters, hard timeout) are in
  # test/models/ssh_key_validator_test.rb; here we only test what the Credential layer
  # itself is responsible for: correctly translating SshKeyValidator's result into
  # validation errors, memoizing correctly, and not leaking the raw bytes.
  # -------------------------------------------------------

  # #inspect is already filtered by Active Record encryption, but the serialization path
  # is outside its jurisdiction. This defense used to exist only on Credential; after
  # extracting it into a concern, both credential types need it.
  test "never includes value when serialized" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")

    refute_includes credential.to_json, "PRIVATE KEY"
    refute_includes credential.as_json.keys, "value"
  end

  private
    # Build a private key string that fits the openssh-key-v1 binary format, to test "does
    # parsing this input cause problems" as an attack surface without relying on ssh-keygen
    # to generate a real key (so the test runs in any CI environment, with no external
    # command). Same logic as the helper of the same name in SshKeyValidatorTest; here we
    # only need to "trigger one real parse attempt", not cover KDF/timeout scenarios
    # (those are in SshKeyValidatorTest).
    def openssh_key(type_name:)
      magic = "openssh-key-v1\0"
      check = "\x01\x02\x03\x04"
      fixed = check + check + ssh_string(type_name)
      pad = (-fixed.bytesize) % 16
      pad = 16 if pad.zero?
      privsection = fixed + ("\x00" * pad)

      body = +""
      body << ssh_string("none")
      body << ssh_string("none")
      body << ssh_string("")
      body << [ 1 ].pack("N")
      body << ssh_string("")
      body << ssh_string(privsection)

      raw = magic + body
      b64 = [ raw ].pack("m0").scan(/.{1,70}/).join("\n")
      "-----BEGIN OPENSSH PRIVATE KEY-----\n#{b64}\n-----END OPENSSH PRIVATE KEY-----"
    end

    def ssh_string(bytes)
      [ bytes.bytesize ].pack("N") + bytes
    end
end
