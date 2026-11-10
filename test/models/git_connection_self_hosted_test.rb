require "test_helper"

class GitConnectionSelfHostedTest < ActiveSupport::TestCase
  def build(provider, **urls)
    GitConnection.new(name: "c", provider: provider, token: "t0ken_value", **urls).tap(&:validate)
  end

  test "blank URLs use the public service" do
    connection = build("gitlab")
    assert_equal [ "https://gitlab.com/api/v4", "https://gitlab.com" ], [ connection.api_url, connection.web_url ]
  end

  test "a self-hosted web URL alone is enough: the API path is added per platform" do
    assert_equal "https://git.corp/api/v4", build("gitlab", web_url: "https://git.corp/").api_url
    assert_equal "https://ghe.corp/api/v3", build("github", web_url: "https://ghe.corp").api_url
    assert_equal "http://gitee.corp:8080/api/v5", build("gitee", web_url: "http://gitee.corp:8080").api_url
  end

  test "a self-hosted API URL alone gives the web URL, not the public one" do
    assert_equal "https://git.corp", build("gitlab", api_url: "https://git.corp/api/v4").web_url
    assert_equal "http://git.corp:8929", build("gitlab", api_url: "http://git.corp:8929/gitlab-api").web_url
    assert_equal "https://github.com", build("github", api_url: "https://api.github.com").web_url
  end

  test "the CA certificate must be PEM; blank means none" do
    assert_includes build("gitlab", ca_certificate: "not a cert").errors[:ca_certificate], I18n.t("activerecord.errors.models.git_connection.attributes.ca_certificate.invalid_pem")
    connection = build("gitlab", ca_certificate: "  \n")
    assert_nil connection.ca_certificate
    assert connection.valid?
    assert build("gitlab", ca_certificate: TlsTestServer.certificate.to_pem).valid?
  end

  test "changing the CA certificate needs the token typed again" do
    connection = GitConnection.create!(name: "corp", provider: "gitlab", web_url: "https://git.corp", token: "t0ken_value")

    assert_not connection.update(ca_certificate: TlsTestServer.certificate.to_pem)
    assert connection.errors.of_kind?(:token, :required_with_new_ca_certificate)

    connection.token_reentered = true
    assert connection.update(ca_certificate: TlsTestServer.certificate.to_pem, token: "n3w_token_value")
  end

  test "a self-signed server is refused until its certificate is trusted" do
    TlsTestServer.run do |url|
      connection = GitConnection.create!(name: "corp", provider: "gitlab", api_url: url, token: "t0ken_value")

      error = assert_raises(GitProviders::Error) { connection.check! }
      assert_equal :tls, error.key

      connection.update!(ca_certificate: TlsTestServer.certificate.to_pem, token: "t0ken_value", token_reentered: true)
      assert_equal "me", connection.check!
    end
  end
end
