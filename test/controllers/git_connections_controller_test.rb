require "test_helper"

class GitConnectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @connection = GitConnection.create!(name: "github", provider: "github", token: "ghp_original_token_aaaa")
  end

  test "denies non-admins every action" do
    [ users(:one), users(:three) ].each do |user|
      sign_in_as user

      get git_connections_path
      assert_redirected_to root_path
      get new_git_connection_path
      assert_redirected_to root_path
      get edit_git_connection_path(@connection)
      assert_redirected_to root_path

      assert_no_difference -> { GitConnection.count } do
        post git_connections_path, params: { git_connection: { name: "x", provider: "github", token: "t" } }
      end
      patch git_connection_path(@connection), params: { git_connection: { token: "stolen" } }
      delete git_connection_path(@connection)
      post check_git_connection_path(@connection)
      assert_redirected_to root_path
    end

    assert_equal "ghp_original_token_aaaa", @connection.reload.token
    assert_equal 0, AuditLog.where("action_name LIKE 'git_connection.%'").count
  end

  test "admin adds a connection; it is audited and the token is never rendered back" do
    sign_in_as users(:two)

    assert_difference -> { GitConnection.count } do
      post git_connections_path, params: { git_connection: {
        name: "公司 GitLab", provider: "gitlab", api_url: "https://git.example.com/api/v4",
        web_url: "https://git.example.com", token: "glpat-very-secret-1234"
      } }
    end
    assert_redirected_to git_connections_path

    created = GitConnection.find_by!(name: "公司 GitLab")
    assert_equal "glpat-very-secret-1234", created.token
    log = AuditLog.where(action_name: "git_connection.create").sole
    assert_equal "公司 GitLab", log.detail

    get git_connections_path
    assert_response :success
    assert_no_match "glpat-very-secret-1234", response.body
    assert_match "…1234", response.body

    get edit_git_connection_path(created)
    assert_no_match "glpat-very-secret-1234", response.body
  end

  test "a blank token on edit keeps the current one; a new token is audited as a rotation" do
    sign_in_as users(:two)

    patch git_connection_path(@connection), params: { git_connection: { name: "GitHub.com", token: "" } }
    assert_equal "ghp_original_token_aaaa", @connection.reload.token
    assert_equal "GitHub.com", @connection.name
    assert AuditLog.exists?(action_name: "git_connection.update")

    patch git_connection_path(@connection), params: { git_connection: { token: "ghp_rotated_token_bbbb" } }
    assert_equal "ghp_rotated_token_bbbb", @connection.reload.token
    assert AuditLog.exists?(action_name: "git_connection.rotate")
  end

  test "a new API URL needs the token typed again; the stored one is never pointed elsewhere" do
    sign_in_as users(:two)

    patch git_connection_path(@connection),
          params: { git_connection: { api_url: "https://evil.example.net/api/v3", token: "" } }
    assert_response :unprocessable_entity
    assert_equal "https://api.github.com", @connection.reload.api_url
    assert_not AuditLog.exists?(action_name: %w[git_connection.update git_connection.rotate])

    patch git_connection_path(@connection),
          params: { git_connection: { api_url: "https://ghe.example.com/api/v3", token: "ghp_for_ghe_cccc" } }
    assert_redirected_to git_connections_path
    assert_equal [ "https://ghe.example.com/api/v3", "ghp_for_ghe_cccc" ], [ @connection.reload.api_url, @connection.token ]
    assert AuditLog.exists?(action_name: "git_connection.rotate")
  end

  test "the provider can't be switched after creation" do
    sign_in_as users(:two)

    patch git_connection_path(@connection), params: { git_connection: { provider: "gitlab" } }

    assert_equal "github", @connection.reload.provider
  end

  test "a non-http API URL is refused" do
    sign_in_as users(:two)

    post git_connections_path, params: { git_connection: { name: "evil", provider: "github",
                                                           api_url: "file:///etc/passwd", token: "t" } }

    assert_response :unprocessable_entity
    assert_not GitConnection.exists?(name: "evil")
  end

  test "deleting an unused connection is audited" do
    sign_in_as users(:two)

    delete git_connection_path(@connection)

    assert_not GitConnection.exists?(@connection.id)
    assert AuditLog.exists?(action_name: "git_connection.delete", detail: "github")
  end

  test "deleting a connection in use is blocked, naming the apps" do
    ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                       git_connection: @connection, repository: "acme/blog")
    sign_in_as users(:two)

    get git_connections_path
    assert_select "form[action=?][method=post] input[name=_method][value=delete]", git_connection_path(@connection), count: 0

    delete git_connection_path(@connection)

    assert GitConnection.exists?(@connection.id)
    assert_match "blog", flash[:alert]
    assert_not AuditLog.exists?(action_name: "git_connection.delete")
  end

  test "test connection reports who the token belongs to, or why it failed" do
    sign_in_as users(:two)

    stub_http("GET https://api.github.com/user" => [ 200, { login: "octo" } ]) do
      post check_git_connection_path(@connection)
    end
    assert_redirected_to git_connections_path
    assert_match "octo", flash[:notice]

    stub_http("GET https://api.github.com/user" => [ 401, { message: "Bad credentials" } ]) do
      post check_git_connection_path(@connection)
    end
    assert_match "token 无效或已过期", flash[:alert]
  end
end
