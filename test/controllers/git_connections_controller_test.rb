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
end
