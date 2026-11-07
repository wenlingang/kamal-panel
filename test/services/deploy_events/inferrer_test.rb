require "test_helper"

class DeployEvents::InferrerTest < ActiveSupport::TestCase
  setup do
    @managed_app = ManagedApp.create!(name: "blog",
                                      config_yaml: file_fixture("two_host_deploy.yml").read,
                                      destination: "production")
  end

  # The two machines of two_host_deploy.yml; one "full convergence" requires both to have reachable,
  # running observations
  HOSTS = %w[10.0.0.1 10.0.0.2].freeze

  def observe(host:, version:, status: "running", reachable: true, at: Time.current, role: "web")
    Observation.create!(managed_app: @managed_app, host: host, role: role,
                        container_name: "blog-#{role}-production-#{version}",
                        version: version, docker_status: status,
                        reachable: reachable, observed_at: at)
  end

  def converge(version:, at: Time.current)
    HOSTS.each { |host| observe(host: host, version: version, at: at) }
  end

  test "records an inferred event when the converged version changes" do
    converge(version: "aaaaaaa", at: 10.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)

    converged_at = 1.minute.ago
    converge(version: "bbbbbbb", at: converged_at)
    DeployEvents::Inferrer.call(@managed_app)

    event = @managed_app.deploy_events.sole
    assert_equal "bbbbbbb", event.version
    assert_equal "inferred", event.source
    assert_nil event.started_at
    assert_nil event.performer
    assert_nil event.command
    assert_in_delta converged_at, event.succeeded_at, 1.second
    assert_in_delta converged_at, event.observed_at, 1.second
    assert_equal "bbbbbbb", @managed_app.reload.last_converged_version
  end
end
