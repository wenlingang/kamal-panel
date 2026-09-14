require "test_helper"

class AuditLogTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email_address: "op@example.com", password: "secret123456", role: "admin")
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  # 动作名在页面上要翻译，翻译不到就会退回原始的 action_name（给"代码里已经
  # 改名、审计行还留着旧名"兜底）。那条回退同时会掩盖"新加了动作忘了写译文"
  # ——所以这里正面盯住覆盖，而不是指望有人肉眼发现页面上冒出一个英文 key。
  test "每个会被写进审计的动作名都有中英文译文" do
    AuditLog.all_action_names.each do |name|
      %i[zh-CN en].each do |locale|
        assert I18n.exists?("audit.actions.#{name}", locale),
               "动作 #{name} 缺 #{locale} 译文"
      end
    end
  end

  test "动作名清单同时覆盖部署动作与权限动作" do
    assert_includes AuditLog.all_action_names, "rollback"
    assert_includes AuditLog.all_action_names, "user.create"
  end

  test "detail_args 存成 JSON，取出来还是原来的结构" do
    log = AuditLog.record_access!(user: @user, action_name: "app.update",
                                  managed_app: @app,
                                  detail_key: "app.update_fields",
                                  detail_args: { "fields" => %w[name kamal_secrets] })

    assert_equal %w[name kamal_secrets], log.reload.detail_args["fields"]
  end

  test "start! 先落一条 pending" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "rollback",
                          target_version: "aaaaaaa", hosts: [ "10.0.0.1" ])

    assert_equal "pending", log.result
    assert_nil log.finished_at
  end

  test "finish! 更新结果与耗时" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "restart",
                          target_version: nil, hosts: [ "10.0.0.1" ])
    log.finish!(result: "success", command: "kamal app restart", output_digest: "ok", duration_ms: 1234)

    assert_equal "success", log.reload.result
    assert_equal 1234, log.duration_ms
    assert_not_nil log.finished_at
  end

  test "审计日志不可删除" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "stop",
                          target_version: nil, hosts: [])

    assert_raises(ActiveRecord::ReadOnlyRecord) { log.destroy }
  end

  test "审计日志也不能用 delete 绕过" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "stop",
                          target_version: nil, hosts: [])

    assert_raises(ActiveRecord::ReadOnlyRecord) { log.delete }
  end

  test "中途崩溃留下的 pending 记录仍可查" do
    AuditLog.start!(user: @user, managed_app: @app, action_name: "rollback",
                    target_version: "aaaaaaa", hosts: [ "10.0.0.1" ])

    assert_equal 1, AuditLog.where(result: "pending").count
  end

  test "销毁 ManagedApp 不会连带删除它的审计日志" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "stop",
                          target_version: nil, hosts: [])

    assert_raises(ActiveRecord::InvalidForeignKey) { @app.destroy! }
    assert AuditLog.exists?(log.id)
  end

  test "销毁 User 不会连带删除它的审计日志" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "stop",
                          target_version: nil, hosts: [])

    assert_raises(ActiveRecord::InvalidForeignKey) { @user.destroy! }
    assert AuditLog.exists?(log.id)
  end

  test "AuditLog.delete_all 绕不过守卫" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "stop",
                          target_version: nil, hosts: [])

    assert_raises(ActiveRecord::ReadOnlyRecord) { AuditLog.delete_all }
    assert AuditLog.exists?(log.id)
  end

  test "relation.delete_all 绕不过守卫" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "stop",
                          target_version: nil, hosts: [])

    assert_raises(ActiveRecord::ReadOnlyRecord) { AuditLog.where(id: log.id).delete_all }
    assert AuditLog.exists?(log.id)
  end

  test "AuditLog.delete(id) 绕不过守卫" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "stop",
                          target_version: nil, hosts: [])

    assert_raises(ActiveRecord::ReadOnlyRecord) { AuditLog.delete(log.id) }
    assert AuditLog.exists?(log.id)
  end

  test "AuditLog.delete_by 绕不过守卫" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "stop",
                          target_version: nil, hosts: [])

    assert_raises(ActiveRecord::ReadOnlyRecord) { AuditLog.delete_by(id: log.id) }
    assert AuditLog.exists?(log.id)
  end

  test "finish! 拒绝非法的 result，不留下半更新的行" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "restart",
                          target_version: nil, hosts: [])

    assert_raises(ArgumentError) do
      log.finish!(result: "bogus", command: "kamal app restart", output_digest: "??", duration_ms: 1)
    end

    log.reload
    assert_equal "pending", log.result
    assert_nil log.finished_at
    assert_nil log.duration_ms
  end

  test "权限变更记成不属于任何应用的一条审计" do
    log = AuditLog.record_access!(user: users(:two), action_name: "user.update_role",
                                  target_user: users(:one))

    assert_nil log.managed_app
    assert_equal users(:one), log.target_user
    assert_equal "success", log.result
    assert_not_nil log.finished_at, "权限变更是当场完成的，不该留在 pending"
  end

  test "成员变更同时带应用与被操作的人" do
    log = AuditLog.record_access!(user: users(:two), action_name: "app.add_member",
                                  target_user: users(:three), managed_app: @app)

    assert_equal @app, log.managed_app
    assert_equal users(:three), log.target_user
  end

  test "权限变更的记录一样删不掉" do
    log = AuditLog.record_access!(user: users(:two), action_name: "user.deactivate",
                                  target_user: users(:one))

    assert_raises(ActiveRecord::ReadOnlyRecord) { log.destroy }
  end
end
