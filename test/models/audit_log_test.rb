require "test_helper"

class AuditLogTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email_address: "op@example.com", password: "secret123456", role: "admin")
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  # Action names are translated on the page, and when no translation is found it falls
  # back to the raw action_name (a safety net for "renamed in code, audit rows still carry
  # the old name"). That fallback also masks "added a new action but forgot the
  # translation" -- so here we check coverage head-on, rather than hoping someone spots
  # an English key popping up on the page.
  test "every action name written to the audit log has Chinese and English translations" do
    AuditLog.all_action_names.each do |name|
      %i[zh-CN en].each do |locale|
        assert I18n.exists?("audit.actions.#{name}", locale),
               "action #{name} is missing its #{locale} translation"
      end
    end
  end

  test "audit logs cannot be destroyed" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "stop",
                          target_version: nil, hosts: [])

    assert_raises(ActiveRecord::ReadOnlyRecord) { log.destroy }
  end

  test "audit logs cannot be bypassed with delete either" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "stop",
                          target_version: nil, hosts: [])

    assert_raises(ActiveRecord::ReadOnlyRecord) { log.delete }
  end

  test "AuditLog.delete_all cannot bypass the guard" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "stop",
                          target_version: nil, hosts: [])

    assert_raises(ActiveRecord::ReadOnlyRecord) { AuditLog.delete_all }
    assert AuditLog.exists?(log.id)
  end
end
