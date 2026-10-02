require "test_helper"

class ManagedAppTest < ActiveSupport::TestCase
  def valid_yaml
    file_fixture("simple_deploy.yml").read
  end

  test "can only be saved when parsing succeeds" do
    app = ManagedApp.new(name: "blog", config_yaml: valid_yaml, destination: "production")
    assert app.valid?
  end

  test "rejects an unparseable deploy.yml and gives the reason" do
    app = ManagedApp.new(name: "broken", config_yaml: "不是配置")

    refute app.valid?
    assert_match(/无法解析/, app.errors[:config_yaml].join)
  end

  # --- destination ends up as part of a filename used to build a path, see the same-named
  # comment in Kamal::ConfigParser; here we only test ManagedApp's own responsibility:
  # block invalid destinations at the outermost layer and give a user-readable error,
  # instead of letting the request reach Kamal::ConfigParser and hit a filesystem
  # exception or worse. ------

  test "rejects a destination with path traversal sequences, with an explanation rather than a filesystem error" do
    app = ManagedApp.new(name: "blog", config_yaml: valid_yaml, destination: "../../../../tmp/PWNED")

    refute app.valid?
    assert_match(/简短的标识符/, app.errors[:destination].join)
    refute_match(/无法解析/, app.errors.full_messages.join, "should not get as far as failing in ConfigParser")
  end

  test "rejects a destination over the length limit instead of hitting the filesystem filename limit" do
    app = ManagedApp.new(name: "blog", config_yaml: valid_yaml, destination: "x" * 64)

    refute app.valid?
    assert_match(/简短的标识符/, app.errors[:destination].join)
  end

  test "accepts normal short destinations (hyphens, digits, blank)" do
    [ "production", "staging", "eu-west", "prod2", "" ].each do |dest|
      app = ManagedApp.new(name: "blog-#{dest.presence || 'blank'}", config_yaml: valid_yaml, destination: dest)

      assert app.valid?, "destination=#{dest.inspect} should pass validation, actual errors: #{app.errors.full_messages.inspect}"
    end
  end

  test "exposes the parsed service name and hosts" do
    app = ManagedApp.create!(name: "blog", config_yaml: valid_yaml, destination: "production")

    assert_equal "blog", app.service
    assert_equal [ "127.0.0.1" ], app.app_hosts
  end

  test "caches the parse result on the instance without spawning a subprocess again" do
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

  test "servers in the destination file override the base deploy.yml (rather than being ignored)" do
    app = ManagedApp.create!(
      name: "blog",
      config_yaml: valid_yaml,
      destination: "production",
      destination_config_yaml: destination_override_yaml
    )

    assert_equal [ "10.0.0.9" ], app.app_hosts
  end

  test "assigning destination_config_yaml invalidates the cached parse result" do
    app = ManagedApp.create!(name: "blog", config_yaml: valid_yaml, destination: "production")

    assert_equal [ "127.0.0.1" ], app.app_hosts

    app.destination_config_yaml = destination_override_yaml

    assert_equal [ "10.0.0.9" ], app.app_hosts
  end

  test "reload invalidates the cached parse result -- otherwise stale config would look just like the bug already fixed" do
    app = ManagedApp.create!(name: "blog", config_yaml: valid_yaml, destination: "production")
    assert_equal [ "127.0.0.1" ], app.app_hosts

    # Bypass the app's own writer and change this row directly in the database -- simulating
    # another instance (e.g. a background polling job) having updated the record, and this
    # instance reloading the new data.
    ManagedApp.find(app.id).update_column(:config_yaml, valid_yaml.gsub("127.0.0.1", "10.0.0.9"))

    app.reload

    assert_equal [ "10.0.0.9" ], app.app_hosts
  end

  test "update! goes through the custom writer and invalidates the cache (assign_attributes calls setters one by one)" do
    app = ManagedApp.create!(name: "blog", config_yaml: valid_yaml, destination: "production")
    assert_equal [ "127.0.0.1" ], app.app_hosts

    app.update!(config_yaml: valid_yaml.gsub("127.0.0.1", "10.0.0.9"))

    assert_equal [ "10.0.0.9" ], app.app_hosts
  end

  # When both places define the same variable, whichever one wins, deploy quietly uses the
  # wrong password, and the failure scene (can't pull the image) is far from the cause.
  # Fail loudly while a human can still fix it.
  test "saving is rejected when kamal_secrets and the registry credential collide on the same variable" do
    app = ManagedApp.new(name: "blog",
                         config_yaml: file_fixture("registry_env_deploy.yml").read,
                         kamal_secrets: "MY_OWN_REGISTRY_TOKEN=from-free-text\n",
                         registry_credential: RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t"))

    refute_predicate app, :valid?
    assert_match "MY_OWN_REGISTRY_TOKEN", app.errors[:kamal_secrets].join
  end

  test "saves normally when the collision is on a different variable" do
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
  test "an invalid destination with a registry credential selected gives a form error, not an exception" do
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
  test "deactivating stamps a timestamp and releases both credential bindings" do
    app = deactivatable_app

    app.deactivate!

    assert_predicate app, :deactivated?
    assert_nil app.ssh_credential
    assert_nil app.registry_credential
  end

  # This is the acceptance test for the whole thing: once credentials are shared in a pool
  # they can't be deleted while referenced, and "switch the app to another credential
  # first" makes no sense when deactivating -- what you want is to take it fully offline.
  test "after deactivation, the credentials it used to hold can be deleted" do
    app = deactivatable_app
    credential = app.ssh_credential

    refute credential.destroy, "should not be deletable while still referenced"

    app.deactivate!

    assert credential.reload.destroy
  end

  test "activating only clears the timestamp; credentials must be chosen again" do
    app = deactivatable_app
    app.deactivate!

    app.reactivate!

    refute_predicate app, :deactivated?
    assert_nil app.ssh_credential, "deactivation released the binding, so activation should decide again which key to give it"
  end

  test "the active scope only includes apps that are not deactivated" do
    live = deactivatable_app
    gone = ManagedApp.create!(name: "shop", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    gone.deactivate!

    assert_includes ManagedApp.active, live
    refute_includes ManagedApp.active, gone
  end
end
