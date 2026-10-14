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

  test "lets ops view the audit list, with no delete entry point" do
    AuditLog.start!(user: users(:two), managed_app: @app, action_name: "rollback",
                    target_version: "aaaaaaa", hosts: [ "10.0.0.1" ])

    get audit_logs_path

    assert_response :success
    assert_match "进行中", @response.body
    assert_no_match(/<a[^>]*delete/, @response.body)
    assert_no_match(/method_value=.delete./, @response.body)
    assert_no_match "data-turbo-method=\"delete\"", @response.body
  end

  test "filters by app and keeps the filter on the older-entries link" do
    shop = ManagedApp.create!(name: "shop", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    (AuditLogFilter::PER_PAGE + 1).times do
      AuditLog.start!(user: users(:two), managed_app: @app, action_name: "restart", target_version: nil, hosts: [])
    end
    AuditLog.start!(user: users(:two), managed_app: shop, action_name: "restart", target_version: "only-in-shop", hosts: [])

    get audit_logs_path(app_id: @app.id)

    assert_select "tbody tr", AuditLogFilter::PER_PAGE
    assert_no_match "only-in-shop", @response.body
    assert_select "p.pager a[href*=?][href*=?]", "app_id=#{@app.id}", "before="
  end

  # Anyone signed in can read the audit page, but only admins can see the people list. The
  # dropdowns must not become a back door to it: they offer only what the log itself already shows.
  test "the actor and app dropdowns only offer what appears in the log" do
    User.create!(email_address: "never-acted@example.com", password: "password-123", role: "ops")
    ManagedApp.create!(name: "never-touched", config_yaml: file_fixture("simple_deploy.yml").read,
                       destination: "production")
    AuditLog.start!(user: users(:two), managed_app: @app, action_name: "restart", target_version: nil, hosts: [])

    get audit_logs_path

    assert_select "select#user_id option", text: /two@example\.com/
    assert_no_match "never-acted@example.com", @response.body
    assert_select "select#app_id option", text: "blog"
    assert_no_match "never-touched", @response.body
  end

  test "deploy rows link to their output for someone allowed to run the action" do
    log = AuditLog.start!(user: users(:two), managed_app: @app, action_name: "restart", target_version: nil, hosts: [])
    sign_in_as(users(:two)) # admin

    get audit_logs_path

    assert_select "a[href=?]", managed_app_action_path(@app, log)
  end

  test "no output link for someone the output page would turn away" do
    log = AuditLog.start!(user: users(:two), managed_app: @app, action_name: "restart", target_version: nil, hosts: [])
    sign_in_as(users(:three)) # developer, not a member of this app

    get audit_logs_path

    assert_select "a[href=?]", managed_app_action_path(@app, log), count: 0
  end

  test "a pending row that has outlived any possible run is shown as interrupted" do
    AuditLog.start!(user: users(:two), managed_app: @app, action_name: "rollback",
                    target_version: "aaaaaaa", hosts: [ "10.0.0.1" ])

    travel AuditLog::INTERRUPTED_AFTER + 1.minute do
      get audit_logs_path
    end

    assert_select "td strong", text: I18n.t("audit_logs.index.interrupted")
    assert_no_match ">#{I18n.t('audit_logs.index.pending')}<", @response.body
  end

  # Accountability looks at the email, day-to-day recognition looks at the nickname -- the audit
  # page shows both. With only the nickname, two people with the same name (nicknames aren't
  # required to be unique) couldn't be told apart on this page.
  test "shows the actor's nickname and email" do
    users(:two).update!(nickname: "老王")
    AuditLog.record_access!(user: users(:two), action_name: "user.deactivate",
                            target_user: users(:one))

    get audit_logs_path

    assert_response :success
    assert_select "td", text: /老王/
    assert_select "td", text: /two@example.com/
  end

  test "shows only the email for an actor without a nickname" do
    AuditLog.record_access!(user: users(:two), action_name: "user.deactivate",
                            target_user: users(:one))

    get audit_logs_path

    assert_select "td", text: "two@example.com"
  end

  test "shows the target user's nickname and email too" do
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
  test "renders legacy audit rows that only have detail as-is, without translation" do
    AuditLog.record_access!(user: users(:two), action_name: "credential.rotate",
                            detail: "生产集群")

    get audit_logs_path

    assert_select "td", text: "生产集群"
  end

  test "renders detail_key rows in the current locale" do
    AuditLog.record_access!(user: users(:two), action_name: "user.create",
                            detail_key: "user.password_by_admin")

    get audit_logs_path

    assert_select "td", text: "密码由管理员直接设置"
  end

  # When both "the person acted on" and "target description" are present, show them together.
  # Previously this column took the first non-blank, user.create writes both, so that second half
  # would never be visible -- written but never shown is as good as not recorded.
  test "shows both the target user and the object description when both exist" do
    AuditLog.record_access!(user: users(:two), action_name: "user.create",
                            target_user: users(:one),
                            detail_key: "user.password_by_admin")

    get audit_logs_path

    assert_select "td", text: /one@example\.com/
    assert_select "td", text: /密码由管理员直接设置/
  end

  # Field names must be translated one by one and then joined; the joiner itself is also
  # language-dependent.
  test "translates app.update field names one by one and joins them" do
    AuditLog.record_access!(user: users(:two), action_name: "app.update", managed_app: @app,
                            detail_key: "app.update_fields",
                            detail_args: { "fields" => %w[ssh_credential_id kamal_secrets] })

    get audit_logs_path

    assert_select "td", text: /SSH 私钥、\.kamal\/secrets 内容/
  end

  test "renders action names as localized labels" do
    AuditLog.record_access!(user: users(:two), action_name: "app.deactivate",
                            managed_app: @app, detail: "blog")

    get audit_logs_path

    assert_select "td", text: "停用应用"
    assert_select "td", text: "blog"
  end

  # The case where the code was renamed but audit rows still carry the old name: must not crash, and
  # must not show "translation missing". Fall back to the raw string, so it can at least still be
  # traced.
  test "falls back to the raw string for unrecognized action names" do
    AuditLog.record_access!(user: users(:two), action_name: "legacy.something")

    get audit_logs_path

    assert_select "td", text: "legacy.something"
  end

  test "shows which credential a credential event refers to on the audit page" do
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

  test "shows records that belong to no app on the audit page" do
    AuditLog.record_access!(user: users(:two), action_name: "user.deactivate",
                            target_user: users(:one))
    sign_in_as users(:two)

    get audit_logs_path

    assert_response :success
    assert_select "td", text: "停用成员"
    assert_select "td", text: /全站/
  end
end
