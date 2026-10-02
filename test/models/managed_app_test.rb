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

  # --- destination ends up as part of a filename used to build a path, see the same-named
  # comment in Kamal::ConfigParser; here we only test ManagedApp's own responsibility:
  # block invalid destinations at the outermost layer and give a user-readable error,
  # instead of letting the request reach Kamal::ConfigParser and hit a filesystem
  # exception or worse. ------

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

    # Bypass the app's own writer and change this row directly in the database -- simulating
    # another instance (e.g. a background polling job) having updated the record, and this
    # instance reloading the new data.
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

  # When both places define the same variable, whichever one wins, deploy quietly uses the
  # wrong password, and the failure scene (can't pull the image) is far from the cause.
  # Fail loudly while a human can still fix it.
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

  # This guards against a real misstep: the variable-collision validation used to rely on
  # a rescue around ParseError. Only when the rescue was removed did we find it wasn't
  # dead code -- when destination is invalid, config_yaml_must_parse returns without
  # parsing and errors[:config_yaml] is empty, so this validation would call the parser,
  # and ConfigParser raises precisely because of that destination. Now it shares the same
  # precondition as config_yaml_must_parse: if destination already reported an error, don't parse.
  test "destination 不合法且选了 registry 凭据时，得到的是表单报错而不是一次异常" do
    app = ManagedApp.new(name: "blog",
                         config_yaml: "::: 这不是 YAML :::",
                         destination: "bad/dest",
                         kamal_secrets: "FOO=1\n",
                         registry_credential: RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t"))

    refute_predicate app, :valid?
    assert_predicate app.errors[:destination], :present?
  end

  # ---- Deactivation (branch app-deactivate) -----------------------------------
  #
  # Hard deletion is blocked by auditing: audit_logs has a foreign key pointing at
  # managed_apps, and audit rows are by design undeletable. This is the same shape as
  # "users only deactivate, never delete", and the answer is the same.

  def deactivatable_app
    ManagedApp.create!(
      name: "blog", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production",
      ssh_credential: Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群"),
      registry_credential: RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t")
    )
  end

  # These two must live and die together: nulling without deactivating, the app keeps
  # being collected but has no key; deactivating without nulling, the credential still
  # can't be deleted -- and the original problem would have gone unsolved.
  test "停用会打时间戳并同时释放两个凭据绑定" do
    app = deactivatable_app

    app.deactivate!

    assert_predicate app, :deactivated?
    assert_nil app.ssh_credential
    assert_nil app.registry_credential
  end

  # This is the acceptance test for the whole thing: once credentials are shared in a pool
  # they can't be deleted while referenced, and "switch the app to another credential
  # first" makes no sense when deactivating -- what you want is to take it fully offline.
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
