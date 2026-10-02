require "test_helper"

class RollbackCandidatesTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog",
                              config_yaml: file_fixture("two_host_deploy.yml").read,
                              destination: "production")
    @now = Time.current
  end

  def observe(host:, version:, status: "exited", role: "web")
    Observation.create!(managed_app: @app, host: host, role: role,
                        container_name: "blog-#{role}-production-#{version}",
                        version: version, docker_status: status,
                        reachable: true, observed_at: @now)
  end

  test "所有主机都有该版本容器时可回滚" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", version: "aaaaaaa")

    entry = RollbackCandidates.new(@app).list.detect { |c| c[:version] == "aaaaaaa" }

    assert entry[:available]
    assert_nil entry[:reason]
  end

  test "某台主机上已被清理时不可回滚，并注明是哪一台" do
    observe(host: "10.0.0.1", version: "aaaaaaa")

    entry = RollbackCandidates.new(@app).list.detect { |c| c[:version] == "aaaaaaa" }

    refute entry[:available]
    assert_match "10.0.0.2", entry[:reason]
  end

  test "当前正在运行的版本不出现在回滚候选中" do
    observe(host: "10.0.0.1", version: "current", status: "running")
    observe(host: "10.0.0.2", version: "current", status: "running")

    versions = RollbackCandidates.new(@app).list.map { |c| c[:version] }

    refute_includes versions, "current"
  end
end
