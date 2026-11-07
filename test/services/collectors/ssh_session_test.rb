require "test_helper"

class Collectors::SshSessionTest < ExecutionLayerTest
  def managed_app
    @managed_app ||= begin
      yaml = <<~YAML
        service: blog
        image: example/blog
        servers:
          web:
            - 127.0.0.1
        registry:
          server: registry.example.com
          username: someone
          password:
            - KAMAL_REGISTRY_PASSWORD
        builder:
          arch: amd64
        ssh:
          user: deploy
          port: #{FakeHost::NODES.fetch("node-1")}
      YAML

      ManagedApp.create!(
        name: "blog",
        config_yaml: yaml,
        destination: "production",
        ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key,
                                        name: "blog 的 SSH 私钥")
      )
    end
  end

  test "capture_many isolates each host's failure without affecting other hosts" do
    session = Collectors::SshSession.new(managed_app)

    results = session.capture_many([ "127.0.0.1" ]) { "echo hello" }

    assert_equal "hello", results["127.0.0.1"].stdout.strip
    assert_nil results["127.0.0.1"].error
  end
end
