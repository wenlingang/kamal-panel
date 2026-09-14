require "test_helper"

class FakeHostSmokeTest < ExecutionLayerTest
  test "两台 fake host 都能 SSH 进去并执行 docker" do
    FakeHost::NODES.each_key do |node|
      assert_match(/Server:/, FakeHost.ssh(node, "docker version"))
    end
  end

  test "每台 fake host 有独立的 docker daemon" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")

    on_node_1 = FakeHost.ssh("node-1", "docker ps --format '{{.Names}}'")
    on_node_2 = FakeHost.ssh("node-2", "docker ps --format '{{.Names}}'")

    assert_includes on_node_1, "blog-web-production-aaaaaaa"
    refute_includes on_node_2, "blog-web-production-aaaaaaa"
  end

  test "可以造出已停止的容器" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "bbbbbbb",
                            state: :stopped)

    running = FakeHost.ssh("node-1", "docker ps --format '{{.Names}}'")
    all     = FakeHost.ssh("node-1", "docker ps -a --format '{{.Names}}'")

    refute_includes running, "blog-web-production-bbbbbbb"
    assert_includes all, "blog-web-production-bbbbbbb"
  end
end
