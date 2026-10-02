require "test_helper"

class AuditLogsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one)) # ops: audit records are read-only, and ops can see them too
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  test "未登录时无法查看审计列表" do
    delete session_path # log out

    get audit_logs_path

    assert_redirected_to new_session_path
  end

  test "ops 可以查看审计列表，且没有删除入口" do
    AuditLog.start!(user: users(:two), managed_app: @app, action_name: "rollback",
                    target_version: "aaaaaaa", hosts: [ "10.0.0.1" ])

    get audit_logs_path

    assert_response :success
    assert_match "进行中或已中断", @response.body
    assert_no_match(/<a[^>]*delete/, @response.body)
    assert_no_match(/method_value=.delete./, @response.body)
    assert_no_match "data-turbo-method=\"delete\"", @response.body
  end

  # Accountability looks at the email, day-to-day recognition looks at the nickname -- the audit
  # page shows both. With only the nickname, two people with the same name (nicknames aren't
  # required to be unique) couldn't be told apart on this page.
  test "操作人显示昵称与邮箱" do
    users(:two).update!(nickname: "老王")
    AuditLog.record_access!(user: users(:two), action_name: "user.deactivate",
                            target_user: users(:one))

    get audit_logs_path

    assert_response :success
    assert_select "td", text: /老王/
    assert_select "td", text: /two@example.com/
  end

  test "没有昵称的操作人只显示邮箱" do
    AuditLog.record_access!(user: users(:two), action_name: "user.deactivate",
                            target_user: users(:one))

    get audit_logs_path

    assert_select "td", text: "two@example.com"
  end

  test "被操作的人也显示昵称与邮箱" do
    users(:one).update!(nickname: "小李")
    AuditLog.record_access!(user: users(:two), action_name: "user.deactivate",
                            target_user: users(:one))

    get audit_logs_path

    assert_select "td", text: /小李/
    assert_select "td", text: /one@example.com/
  end

  # The "target" column holds three structurally different things: a person, a version, detail. Only
  # the detail path needs translation, and it splits into two kinds -- credential names and app
  # names are [proper nouns], where translating would be wrong; field-name lists and
  # password-setting modes are what should be translated.
  test "老的审计行只有 detail，原样显示，不走翻译" do
    AuditLog.record_access!(user: users(:two), action_name: "credential.rotate",
                            detail: "生产集群")

    get audit_logs_path

    assert_select "td", text: "生产集群"
  end

  test "detail_key 的行按当前语言渲染" do
    AuditLog.record_access!(user: users(:two), action_name: "user.create",
                            detail_key: "user.password_by_admin")

    get audit_logs_path

    assert_select "td", text: "密码由管理员直接设置"
  end

  # When both "the person acted on" and "target description" are present, show them together.
  # Previously this column took the first non-blank, user.create writes both, so that second half
  # would never be visible -- written but never shown is as good as not recorded.
  test "被操作的人与对象说明同时存在时都显示" do
    AuditLog.record_access!(user: users(:two), action_name: "user.create",
                            target_user: users(:one),
                            detail_key: "user.password_by_admin")

    get audit_logs_path

    assert_select "td", text: /one@example\.com/
    assert_select "td", text: /密码由管理员直接设置/
  end

  # Field names must be translated one by one and then joined; the joiner itself is also
  # language-dependent.
  test "app.update 的字段名逐个翻译后拼接" do
    AuditLog.record_access!(user: users(:two), action_name: "app.update", managed_app: @app,
                            detail_key: "app.update_fields",
                            detail_args: { "fields" => %w[ssh_credential_id kamal_secrets] })

    get audit_logs_path

    assert_select "td", text: /SSH 私钥、\.kamal\/secrets 内容/
  end

  test "动作名显示成中文" do
    AuditLog.record_access!(user: users(:two), action_name: "app.deactivate",
                            managed_app: @app, detail: "blog")

    get audit_logs_path

    assert_select "td", text: "停用应用"
    assert_select "td", text: "blog"
  end

  # The case where the code was renamed but audit rows still carry the old name: must not crash, and
  # must not show "translation missing". Fall back to the raw string, so it can at least still be
  # traced.
  test "认不出的动作名退回原始字符串" do
    AuditLog.record_access!(user: users(:two), action_name: "legacy.something")

    get audit_logs_path

    assert_select "td", text: "legacy.something"
  end

  test "凭据事件在审计页上显示得出是哪条凭据" do
    # A credential is neither a user nor a version; its "target" exists only in detail. If this
    # column doesn't read detail, credential audit rows show as a dash to humans, which is as good
    # as not recorded.
    AuditLog.record_access!(user: users(:two), action_name: "credential.rotate",
                            detail: "生产集群")
    sign_in_as users(:two)

    get audit_logs_path

    assert_response :success
    assert_select "td", text: "替换私钥"
    assert_select "td", text: "生产集群"
  end

  test "审计页能显示不属于任何应用的记录" do
    AuditLog.record_access!(user: users(:two), action_name: "user.deactivate",
                            target_user: users(:one))
    sign_in_as users(:two)

    get audit_logs_path

    assert_response :success
    assert_select "td", text: "停用成员"
    assert_select "td", text: /全站/
  end
end
