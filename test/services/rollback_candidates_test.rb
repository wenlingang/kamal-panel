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

  test "is not rollbackable when one host has pruned it, and names which host" do
    observe(host: "10.0.0.1", version: "aaaaaaa")

    entry = RollbackCandidates.new(@app).list.detect { |c| c[:version] == "aaaaaaa" }

    refute entry[:available]
    assert_match "10.0.0.2", entry[:reason]
  end
end
