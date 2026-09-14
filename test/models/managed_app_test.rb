require "test_helper"

class ManagedAppTest < ActiveSupport::TestCase
  def valid_yaml
    file_fixture("simple_deploy.yml").read
  end

  test "解析成功才能保存" do
    app = ManagedApp.new(name: "blog", config_yaml: valid_yaml, destination: "production")
    assert app.valid?
  end

  test "无法解析的 deploy.yml 被拒绝，并给出原因" do
    app = ManagedApp.new(name: "broken", config_yaml: "不是配置")

    refute app.valid?
    assert_match(/无法解析/, app.errors[:config_yaml].join)
  end

  # --- destination 最终会被当成文件名的一部分去拼路径，见
  # Kamal::ConfigParser 的同名注释；这里只测 ManagedApp 这一层的职责：
  # 把不合法的 destination 挡在最外面，给出用户看得懂的中文报错，而不是
  # 让请求走到 Kamal::ConfigParser、撞上一个文件系统异常或者更糟。------

  test "destination 带路径穿越序列时被拒绝，给出解释而不是文件系统异常" do
    app = ManagedApp.new(name: "blog", config_yaml: valid_yaml, destination: "../../../../tmp/PWNED")

    refute app.valid?
    assert_match(/简短的标识符/, app.errors[:destination].join)
    refute_match(/无法解析/, app.errors.full_messages.join, "不应该走到 ConfigParser 那一层才报错")
  end

  test "destination 超过长度上限时被拒绝，而不是撞上文件系统的文件名长度限制" do
    app = ManagedApp.new(name: "blog", config_yaml: valid_yaml, destination: "x" * 64)

    refute app.valid?
    assert_match(/简短的标识符/, app.errors[:destination].join)
  end

  test "正常的短 destination（含连字符、数字、留空）都能通过校验" do
    [ "production", "staging", "eu-west", "prod2", "" ].each do |dest|
      app = ManagedApp.new(name: "blog-#{dest.presence || 'blank'}", config_yaml: valid_yaml, destination: dest)

      assert app.valid?, "destination=#{dest.inspect} 应该通过校验，实际错误：#{app.errors.full_messages.inspect}"
    end
  end

  test "暴露解析出的服务名与主机" do
    app = ManagedApp.create!(name: "blog", config_yaml: valid_yaml, destination: "production")

    assert_equal "blog", app.service
    assert_equal [ "127.0.0.1" ], app.app_hosts
  end

  test "解析结果在实例内被缓存，不重复开子进程" do
    app = ManagedApp.create!(name: "blog", config_yaml: valid_yaml, destination: "production")

    assert_same app.parsed_config, app.parsed_config
  end

  def destination_override_yaml
    <<~YAML
      servers:
        web:
          - 10.0.0.9
        worker:
          hosts:
            - 10.0.0.9
          cmd: bin/jobs
    YAML
  end

  test "destination 覆盖文件里的 servers 会覆盖基础 deploy.yml（而不是被忽略）" do
    app = ManagedApp.create!(
      name: "blog",
      config_yaml: valid_yaml,
      destination: "production",
      destination_config_yaml: destination_override_yaml
    )

    assert_equal [ "10.0.0.9" ], app.app_hosts
  end

  test "赋值 destination_config_yaml 会让缓存的解析结果失效" do
    app = ManagedApp.create!(name: "blog", config_yaml: valid_yaml, destination: "production")

    assert_equal [ "127.0.0.1" ], app.app_hosts

    app.destination_config_yaml = destination_override_yaml

    assert_equal [ "10.0.0.9" ], app.app_hosts
  end

  test "reload 会让缓存的解析结果失效——否则拿旧配置连线，看起来和已经修过的那个 bug一模一样" do
    app = ManagedApp.create!(name: "blog", config_yaml: valid_yaml, destination: "production")
    assert_equal [ "127.0.0.1" ], app.app_hosts

    # 绕开 app 自己的 writer，直接改数据库里这一行——模拟另一个实例（例如后台
    # 轮询任务）更新了这行记录之后，本实例 reload 出的新数据。
    ManagedApp.find(app.id).update_column(:config_yaml, valid_yaml.gsub("127.0.0.1", "10.0.0.9"))

    app.reload

    assert_equal [ "10.0.0.9" ], app.app_hosts
  end

  test "update! 会经过自定义 writer 使缓存失效（assign_attributes 是逐个属性调用 setter 的）" do
    app = ManagedApp.create!(name: "blog", config_yaml: valid_yaml, destination: "production")
    assert_equal [ "127.0.0.1" ], app.app_hosts

    app.update!(config_yaml: valid_yaml.gsub("127.0.0.1", "10.0.0.9"))

    assert_equal [ "10.0.0.9" ], app.app_hosts
  end

  # 两处都定义同一个变量时，无论让谁赢，都会在部署时安静地用错一个密码，
  # 而失败现场（拉不动镜像）离原因很远。在人还能改的时候大声失败。
  test "kamal_secrets 与 registry 凭据撞同一个变量时保存被拒" do
    app = ManagedApp.new(name: "blog",
                         config_yaml: file_fixture("registry_env_deploy.yml").read,
                         kamal_secrets: "MY_OWN_REGISTRY_TOKEN=from-free-text\n",
                         registry_credential: RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t"))

    refute_predicate app, :valid?
    assert_match "MY_OWN_REGISTRY_TOKEN", app.errors[:kamal_secrets].join
  end

  test "撞的是别的变量则正常保存" do
    app = ManagedApp.new(name: "blog",
                         config_yaml: file_fixture("registry_env_deploy.yml").read,
                         kamal_secrets: "RAILS_MASTER_KEY=abc\n",
                         registry_credential: RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t"))

    assert_predicate app, :valid?
  end

  # 这条挡的是一次真实的踩空：撞变量那条校验原先靠一个 rescue 兜住 ParseError。
  # 去掉 rescue 时才发现它不是死代码——destination 不合法时 config_yaml_must_parse
  # 直接返回、不去解析，errors[:config_yaml] 是空的，于是这条校验会去调解析，
  # 而 ConfigParser 正是因为那个 destination 抛的异常。现在改成和 config_yaml_must_parse
  # 同一个前提：destination 已经报过错就不再解析。
  test "destination 不合法且选了 registry 凭据时，得到的是表单报错而不是一次异常" do
    app = ManagedApp.new(name: "blog",
                         config_yaml: "::: 这不是 YAML :::",
                         destination: "bad/dest",
                         kamal_secrets: "FOO=1\n",
                         registry_credential: RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t"))

    refute_predicate app, :valid?
    assert_predicate app.errors[:destination], :present?
  end

  # ---- 停用（分支 app-deactivate）-----------------------------------------
  #
  # 真删除被审计挡住：audit_logs 有一条指向 managed_apps 的外键，而审计行
  # 是设计上不可删除的。这和"用户只停用不删除"是同一个形状，答案也一样。

  def deactivatable_app
    ManagedApp.create!(
      name: "blog", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production",
      ssh_credential: Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群"),
      registry_credential: RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t")
    )
  end

  # 这两件事必须同生共死：只置空不停用，应用会继续被采集却没有钥匙；
  # 只停用不置空，凭据照样删不掉——最初那个问题就白解了。
  test "停用会打时间戳并同时释放两个凭据绑定" do
    app = deactivatable_app

    app.deactivate!

    assert_predicate app, :deactivated?
    assert_nil app.ssh_credential
    assert_nil app.registry_credential
  end

  # 这条是整件事的验收：凭据进池共享之后被引用就删不掉，而"先把应用换成别的
  # 凭据"在停用这个场景下没有意义——你要的是把它整个拿下线。
  test "停用之后，它原来占着的凭据可以删了" do
    app = deactivatable_app
    credential = app.ssh_credential

    refute credential.destroy, "还被引用时本来就该删不掉"

    app.deactivate!

    assert credential.reload.destroy
  end

  test "启用只清时间戳，凭据要重新选" do
    app = deactivatable_app
    app.deactivate!

    app.reactivate!

    refute_predicate app, :deactivated?
    assert_nil app.ssh_credential, "停用释放了绑定，启用就该重新决定给它哪把钥匙"
  end

  test "active scope 只包含未停用的应用" do
    live = deactivatable_app
    gone = ManagedApp.create!(name: "shop", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    gone.deactivate!

    assert_includes ManagedApp.active, live
    refute_includes ManagedApp.active, gone
  end
end
