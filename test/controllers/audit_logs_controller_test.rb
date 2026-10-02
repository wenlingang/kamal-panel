require "test_helper"

class AuditLogsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one)) # ops：审计记录只读，ops 也能看
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  test "未登录时无法查看审计列表" do
    delete session_path # 退出登录

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

  # 追责看的是邮箱，日常辨认看的是昵称——审计页两个都给。只给昵称的话，
  # 两个重名的人（昵称不要求唯一）在这一页上就分不出来了。
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

  # 「对象」这一列装着三种结构上不同的东西：人、版本号、detail。只有 detail
  # 这一路需要翻译，而它自己又分两类——凭据名和应用名是【专名】，翻译了反而
  # 是错的；字段名列表和密码设置方式才该翻。
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

  # 「被操作的人」和「对象说明」都在时要一起显示。此前这一列是取第一个非空，
  # user.create 两个都写了，说明那一半就永远看不见——只写不显等于没记。
  test "被操作的人与对象说明同时存在时都显示" do
    AuditLog.record_access!(user: users(:two), action_name: "user.create",
                            target_user: users(:one),
                            detail_key: "user.password_by_admin")

    get audit_logs_path

    assert_select "td", text: /one@example\.com/
    assert_select "td", text: /密码由管理员直接设置/
  end

  # 字段名要逐个翻译再拼，连接符本身也是语言相关的。
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

  # 代码里改过名、审计行还留着旧名的情况：不能崩，也不该显示成
  # "translation missing"。退回原始字符串，至少还查得出来。
  test "认不出的动作名退回原始字符串" do
    AuditLog.record_access!(user: users(:two), action_name: "legacy.something")

    get audit_logs_path

    assert_select "td", text: "legacy.something"
  end

  test "凭据事件在审计页上显示得出是哪条凭据" do
    # 凭据既不是用户也不是版本号，它的"对象"只存在 detail 里；这一列不读
    # detail 的话，凭据审计行对人显示成一个破折号，等于没记。
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
