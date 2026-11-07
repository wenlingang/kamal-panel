require "test_helper"

class RegistryCredentialTest < ActiveSupport::TestCase
  # dotenv's single-quoted values have no usable escape for single quotes or newlines, so
  # these two characters have to be rejected at save time -- otherwise the line the panel
  # assembles would break in the middle and hand the following bytes to dotenv as a
  # different variable.
  test "rejects a password containing a single quote" do
    credential = RegistryCredential.new(name: "Docker Hub", value: "s3c'r3t")

    refute_predicate credential, :valid?
    assert_includes credential.errors[:value].join, "单引号"
  end
end
