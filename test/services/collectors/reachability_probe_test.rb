require "test_helper"

class Collectors::ReachabilityProbeTest < ExecutionLayerTest
  test "逐台报告连通性，不因某台失败而整体失败" do
    yaml = <<~YAML
      service: blog
      image: example/blog
      servers:
        web:
          - 127.0.0.1
          - 192.0.2.1
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

    app = ManagedApp.create!(
      name: "blog", config_yaml: yaml, destination: "production",
      ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key,
                                      name: "blog 的 SSH 私钥")
    )

    result = Collectors::ReachabilityProbe.call(app)

    assert_equal true,  result["127.0.0.1"]
    assert_equal false, result["192.0.2.1"]   # TEST-NET-1，保证连不通
  end
end
