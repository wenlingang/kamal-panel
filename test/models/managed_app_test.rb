require "test_helper"

class ManagedAppTest < ActiveSupport::TestCase
  def valid_yaml
    file_fixture("simple_deploy.yml").read
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
end
