require "test_helper"

class GitConnectionTest < ActiveSupport::TestCase
  test "blank URLs default to the public platform" do
    github = GitConnection.create!(name: "gh", provider: "github", token: "t" * 20)
    gitlab = GitConnection.create!(name: "gl", provider: "gitlab", token: "t" * 20, api_url: "", web_url: " ")

    assert_equal [ "https://api.github.com", "https://github.com" ], [ github.api_url, github.web_url ]
    assert_equal [ "https://gitlab.com/api/v4", "https://gitlab.com" ], [ gitlab.api_url, gitlab.web_url ]
  end

  test "self-hosted URLs are kept, without a trailing slash" do
    connection = GitConnection.create!(name: "own", provider: "gitlab", token: "t" * 20,
                                       api_url: "https://git.example.com/api/v4/", web_url: "https://git.example.com/")

    assert_equal "https://git.example.com/api/v4", connection.api_url
    assert_equal "https://git.example.com", connection.web_url
  end

  test "URLs must be http(s): the panel calls them from the server" do
    connection = GitConnection.new(name: "x", provider: "gitlab", token: "t" * 20, api_url: "file:///etc/passwd")

    assert_not connection.valid?
    assert_includes connection.errors[:api_url], I18n.t("activerecord.errors.models.git_connection.attributes.api_url.not_http")
  end

  test "provider, name and token are required" do
    connection = GitConnection.new(provider: "bitbucket")

    assert_not connection.valid?
    assert connection.errors.of_kind?(:provider, :inclusion)
    assert connection.errors.of_kind?(:name, :blank)
    assert connection.errors.of_kind?(:token, :blank)
  end

  test "the token is encrypted at rest and never serialized" do
    connection = GitConnection.create!(name: "gh", provider: "github", token: "ghp_plaintext_value_42")

    raw = GitConnection.connection.select_value("SELECT token FROM git_connections WHERE id = #{connection.id}")
    assert_not_includes raw, "ghp_plaintext_value_42"
    assert_not connection.as_json.key?("token")
    assert_equal "…e_42", connection.token_hint
  end

  test "can't be deleted while an app uses it" do
    connection = GitConnection.create!(name: "gh", provider: "github", token: "t" * 20)
    ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                       git_connection: connection, repository: "acme/blog")

    assert_not connection.destroy
    assert GitConnection.exists?(connection.id)
  end
end
