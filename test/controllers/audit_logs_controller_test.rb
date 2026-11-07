require "test_helper"

class AuditLogsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one)) # ops: audit records are read-only, and ops can see them too
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  test "blocks unauthenticated users from the audit list" do
    delete session_path # log out

    get audit_logs_path

    assert_redirected_to new_session_path
  end
end
