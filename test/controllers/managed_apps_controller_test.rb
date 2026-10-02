require "test_helper"

class ManagedAppsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(users(:two)) } # admin：接入应用属于写操作

  def valid_yaml
    file_fixture("simple_deploy.yml").read
  end

  def valid_key
    File.read(Rails.root.join("test/fake_host/id_ed25519"))
  end

  test "接入时从池里选凭据" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    registry = RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t")
    sign_in_as users(:two)

    post managed_apps_path, params: {
      managed_app: {
        name: "blog", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production",
        ssh_credential_id: credential.id, registry_credential_id: registry.id
      }
    }

    app = ManagedApp.find_by(name: "blog")
    assert_equal credential, app.ssh_credential
    assert_equal registry, app.registry_credential
  end

  # 创建凭据只剩凭据页一条路径。两条创建路径意味着两套校验、两份测试，
  # 以及它们迟早不一致。
  test "接入表单不再接受当场粘贴的私钥" do
    sign_in_as users(:two)

    assert_no_difference -> { Credential.count } do
      post managed_apps_path, params: {
        managed_app: { name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                       destination: "production" },
        ssh_private_key: FakeHost.private_key
      }
    end
  end

  test "docker ps 输出解析不了时，逐主机文案是「输出无法解析」而不是「失联」" do
    Rails.cache.clear # cached_app_hosts 缓存键含 id，SQLite 回滚后可能复用 id

    app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                             destination: "production")
    Observation.create!(
      managed_app: app, host: "127.0.0.1", reachable: false,
      error: Collectors::ContainerCollector.unparseable_output_error(3), observed_at: Time.current
    )

    get managed_app_path(app)

    assert_response :success
    assert_match "输出无法解析", @response.body
    assert_match "主机可达，但返回的内容读不懂", @response.body
    refute_match "失联", @response.body
  end

  test "一个应用的 deploy.yml 坏掉时，/apps 仍能列出其余应用" do
    good = ManagedApp.create!(name: "good", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    broken = ManagedApp.create!(name: "broken", config_yaml: file_fixture("simple_deploy.yml").read,
                                destination: "production")
    broken.update_column(:config_yaml, "不是配置")

    get managed_apps_path

    assert_response :success
    assert_match "good", @response.body
    assert_match "broken", @response.body
    assert_match "配置无法解析", @response.body
  end

  test "ops 不能接入应用" do
    sign_in_as(users(:one)) # ops

    assert_no_difference "ManagedApp.count" do
      post managed_apps_path, params: {
        managed_app: { name: "blog", config_yaml: valid_yaml }
      }
    end

    assert_redirected_to root_path
  end

  test "ops 访问接入表单会被重定向" do
    sign_in_as(users(:one)) # ops

    get new_managed_app_path

    assert_redirected_to root_path
  end

  test "表单填写的 kamal_secrets / kamal_hooks 确实落到 Invocation 的临时目录里" do
    # 光看 ManagedApp 模型或 Invocation 单测都不能证明用户真的有路可以填这两
    # 个字段——表单/控制器如果没接上，这两列就是「存在但永远是 nil」的死列，
    # 任何证明 Invocation 会用到它们的测试都在测一条用户到不了的路径。这里从
    # HTTP 表单提交开始，一路走到 kamal 子进程真的读到这些内容为止。
    FakeHost.ensure_ready!
    FakeHost.reset_all!

    credential = Credential.create!(kind: "ssh_key", value: valid_key, name: "form-wiring 测试用")

    Dir.mktmpdir("kamal-panel-form-test-") do |probe|
      marker = File.join(probe, "hook-ran")

      post managed_apps_path, params: {
        managed_app: {
          name: "blog-form-wiring",
          config_yaml: valid_yaml,
          destination: "production",
          ssh_credential_id: credential.id,
          kamal_hooks: { "pre-connect" => "#!/bin/sh\nenv > #{marker}\n" }.to_json,
          kamal_secrets: "KAMAL_REGISTRY_PASSWORD=s3cr3t-from-form\n"
        }
      }

      assert_response :redirect

      managed_app = ManagedApp.find_by!(name: "blog-form-wiring")
      assert_equal({ "pre-connect" => "#!/bin/sh\nenv > #{marker}\n" }, managed_app.kamal_hooks_scripts)
      assert_equal "KAMAL_REGISTRY_PASSWORD=s3cr3t-from-form\n", managed_app.kamal_secrets

      # 走一次真正的 kamal 子进程调用——不是读模型属性，而是确认这两列
      # 真的被 Invocation 物化进临时目录，并被 kamal 读到。
      # 临时目录里没有 git 仓库，带 hook 的命令需要显式传 --version。
      KamalCli::Invocation.new(managed_app).run(%w[app details --version v1]) { |_line| }

      assert File.exist?(marker), "表单填写的 kamal_hooks 对应的 hook 应被 kamal 执行"
      dumped = File.read(marker)
      assert_match(/^KAMAL_REGISTRY_PASSWORD=s3cr3t-from-form$/, dumped,
                   "表单填写的 kamal_secrets 应被 kamal 读到并注入 hook 环境")
    end
  end

  test "developer 不能接入新应用" do
    sign_in_as users(:three)

    get new_managed_app_path

    assert_redirected_to root_path
    assert_equal "没有权限执行该操作", flash[:alert]
  end

  test "选中的 registry 凭据与配置里的 registry 对不上时，应用页给出提示" do
    registry = RegistryCredential.create!(name: "别家的", value: "s3cr3t", server: "other.example.com")
    app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                             destination: "production", registry_credential: registry)
    sign_in_as users(:two)

    get managed_app_path(app)

    assert_select "p.warning", text: /other\.example\.com/
  end

  test "对得上时不提示" do
    registry = RegistryCredential.create!(name: "自家的", value: "s3cr3t", server: "registry.example.com")
    app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                             destination: "production", registry_credential: registry)
    sign_in_as users(:two)

    get managed_app_path(app)

    assert_select "p.warning", text: /registry/, count: 0
  end

  # server 留空是允许的（它在 deploy.yml 里本来就有），那就无从比对，也就不提示。
  test "凭据没填 registry 地址时不提示" do
    registry = RegistryCredential.create!(name: "没填地址的", value: "s3cr3t")
    app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                             destination: "production", registry_credential: registry)
    sign_in_as users(:two)

    get managed_app_path(app)

    assert_select "p.warning", text: /registry/, count: 0
  end

  # ---- 编辑应用（分支 app-edit）-------------------------------------------
  #
  # 接入之前这个应用是永久不可变的：没有 update、没有 destroy。凭据进池共享
  # 之后这成了一个硬伤——被引用的凭据删不掉，而"先把应用换成别的凭据"这件事
  # 在面板里根本做不到。

  def editable_app(**attrs)
    ManagedApp.create!({ name: "blog", config_yaml: valid_yaml, destination: "production" }.merge(attrs))
  end

  test "admin 能改配置" do
    app = editable_app

    patch managed_app_path(app), params: { managed_app: { config_yaml: valid_yaml.sub("blog", "blog2") } }

    assert_includes app.reload.config_yaml, "blog2"
  end

  test "名下 developer 能改自己应用的配置" do
    app = editable_app
    AppMembership.create!(user: users(:three), managed_app: app)
    sign_in_as users(:three)

    patch managed_app_path(app), params: { managed_app: { name: "blog-renamed" } }

    assert_equal "blog-renamed", app.reload.name
  end

  test "非名下 developer 改不了别人的应用" do
    app = editable_app
    sign_in_as users(:three)

    patch managed_app_path(app), params: { managed_app: { name: "被别人改了" } }

    assert_equal "blog", app.reload.name
  end

  test "ops 改不了任何应用" do
    app = editable_app
    sign_in_as users(:one)

    patch managed_app_path(app), params: { managed_app: { name: "被 ops 改了" } }

    assert_equal "blog", app.reload.name
  end

  # 改绑凭据实质上是"把哪把私钥交给这个应用用"，而凭据是 admin 独占管理的。
  # 视图里把下拉藏起来只是少一次注定失败的点击；真正的防线必须在参数层，
  # 否则一条手工构造的 PATCH 就能让 developer 给自己的应用换上池子里任何一把钥匙。
  test "developer 伪造带凭据 id 的请求会被参数层丢弃" do
    credential = Credential.create!(kind: "ssh_key", value: valid_key, name: "别人的钥匙")
    app = editable_app
    AppMembership.create!(user: users(:three), managed_app: app)
    sign_in_as users(:three)

    patch managed_app_path(app), params: {
      managed_app: { name: "blog-renamed", ssh_credential_id: credential.id }
    }

    assert_equal "blog-renamed", app.reload.name, "它自己有权改的字段应该照常生效"
    assert_nil app.ssh_credential, "凭据绑定不该被非 admin 改动"
  end

  test "admin 能改绑凭据" do
    credential = Credential.create!(kind: "ssh_key", value: valid_key, name: "生产集群")
    registry = RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t")
    app = editable_app

    patch managed_app_path(app), params: {
      managed_app: { ssh_credential_id: credential.id, registry_credential_id: registry.id }
    }

    app.reload
    assert_equal credential, app.ssh_credential
    assert_equal registry, app.registry_credential
  end

  # destination 决定了容器名，而已有的观测与部署事件都是按旧 destination 记的。
  # 改了它，历史会变成误导。
  test "destination 改不动，哪怕被 POST 上来" do
    app = editable_app

    patch managed_app_path(app), params: { managed_app: { destination: "staging" } }

    assert_equal "production", app.reload.destination
  end

  # cached_app_hosts 的缓存键是三段配置内容的哈希。这条测试守的是那套失效机制：
  # 改了配置却还拿旧解析去连机器，是这个缓存方案存在的全部理由要防的事。
  test "改了配置之后采集的目标机器跟着变" do
    app = editable_app(config_yaml: file_fixture("two_host_deploy.yml").read)
    assert_equal 2, app.cached_app_hosts.size

    patch managed_app_path(app), params: { managed_app: { config_yaml: valid_yaml } }

    assert_equal 1, app.reload.cached_app_hosts.size
  end

  # last_poll_error 记的是【旧内容】的罪。不清掉的话，改完配置后详情页会继续
  # 指控新配置，直到下一轮采集（最长一个 IDLE 周期）。新配置若也坏，下一轮会重新记。
  test "改了配置就清掉旧的轮询错误" do
    app = editable_app
    app.update_columns(last_poll_error: "旧配置解析失败", last_poll_error_at: 1.hour.ago,
                       first_poll_error_at: 1.hour.ago)

    patch managed_app_path(app), params: { managed_app: { config_yaml: valid_yaml.sub("blog", "blog2") } }

    app.reload
    assert_nil app.last_poll_error
    assert_nil app.last_poll_error_at
    assert_nil app.first_poll_error_at
  end

  test "只改了别的字段时不动轮询错误" do
    app = editable_app
    app.update_columns(last_poll_error: "配置确实还坏着", last_poll_error_at: 1.hour.ago)

    patch managed_app_path(app), params: { managed_app: { name: "blog-renamed" } }

    assert_equal "配置确实还坏着", app.reload.last_poll_error
  end

  # 改绑凭据决定这个应用能用哪把钥匙，是一次权限变更；这个仓库的规矩是权限
  # 变更必须留痕。detail 只记字段名——记值就等于把密文写进审计表。
  test "编辑写一条审计，只记改了哪些字段而不记值" do
    credential = Credential.create!(kind: "ssh_key", value: valid_key, name: "生产集群")
    app = editable_app

    patch managed_app_path(app), params: {
      managed_app: { name: "blog-renamed", ssh_credential_id: credential.id }
    }

    log = AuditLog.where(action_name: "app.update").sole
    assert_equal app, log.managed_app
    # 存字段名【数组】而不是拼好的字符串：显示时要按当前语言逐个翻译再拼，
    # 拼好的串没法再拆开翻。
    assert_includes log.detail_args["fields"], "name"
    assert_includes log.detail_args["fields"], "ssh_credential_id"
    refute_includes log.detail_args.to_s, "blog-renamed", "审计只记字段名，不记值"
  end

  test "保存失败时不写审计" do
    app = editable_app

    assert_no_difference -> { AuditLog.count } do
      patch managed_app_path(app), params: { managed_app: { name: "" } }
    end

    assert_response :unprocessable_entity
  end

  # ---- 停用与启用（分支 app-deactivate）------------------------------------

  test "admin 停用应用：释放凭据、写审计" do
    credential = Credential.create!(kind: "ssh_key", value: valid_key, name: "生产集群")
    app = editable_app(ssh_credential: credential)

    post deactivate_managed_app_path(app)

    app.reload
    assert_predicate app, :deactivated?
    assert_nil app.ssh_credential
    assert_equal "blog", AuditLog.where(action_name: "app.deactivate").sole.detail
  end

  test "启用写审计，并且不把凭据找回来" do
    app = editable_app(ssh_credential: Credential.create!(kind: "ssh_key", value: valid_key, name: "生产集群"))
    app.deactivate!

    post reactivate_managed_app_path(app)

    app.reload
    refute_predicate app, :deactivated?
    assert_nil app.ssh_credential
    assert_equal "blog", AuditLog.where(action_name: "app.reactivate").sole.detail
  end

  test "非 admin 停用不了——名下 developer 也不行" do
    app = editable_app
    AppMembership.create!(user: users(:three), managed_app: app)
    sign_in_as users(:three)

    post deactivate_managed_app_path(app)

    refute_predicate app.reload, :deactivated?
  end

  test "停用的应用编辑不了" do
    app = editable_app
    app.deactivate!

    patch managed_app_path(app), params: { managed_app: { name: "改一下试试" } }

    assert_equal "blog", app.reload.name
  end

  test "停用的应用仍然打得开详情页" do
    app = editable_app
    app.deactivate!

    get managed_app_path(app)

    assert_response :success
  end
end
