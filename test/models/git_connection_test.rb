require "test_helper"

class GitConnectionTest < ActiveSupport::TestCase
  test "the token is encrypted at rest and never serialized" do
    connection = GitConnection.create!(name: "gh", provider: "github", token: "ghp_plaintext_value_42")

    raw = GitConnection.connection.select_value("SELECT token FROM git_connections WHERE id = #{connection.id}")
    assert_not_includes raw, "ghp_plaintext_value_42"
    assert_not connection.as_json.key?("token")
    assert_equal "…e_42", connection.token_hint
  end
end
