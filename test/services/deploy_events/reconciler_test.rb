require "test_helper"

class DeployEvents::ReconcilerTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    @observed_at = 3.minutes.ago
  end

  def observe(version:, status: "running", host: "10.0.0.1")
    Observation.create!(managed_app: @app, host: host, role: "web",
                        container_name: "blog-web-production-#{version}",
                        version: version, docker_status: status,
                        reachable: true, observed_at: @observed_at)
  end

  def event(version: "aaaaaaa", succeeded_at: 5.minutes.ago)
    DeployEvent.create!(managed_app: @app, version: version, source: "hook",
                        succeeded_at: succeeded_at)
  end

  test "填的是观测时间，而不是当下" do
    e = event
    observe(version: "aaaaaaa")

    DeployEvents::Reconciler.call(@app)

    assert_in_delta @observed_at, e.reload.observed_at, 1.second
  end

  test "只认 running，exited 不算被观测到" do
    e = event
    observe(version: "aaaaaaa", status: "exited")

    DeployEvents::Reconciler.call(@app)

    assert_nil e.reload.observed_at
  end

  test "已经填过的不被后来的观测覆写" do
    first = 10.minutes.ago
    e = event
    e.update!(observed_at: first)
    observe(version: "aaaaaaa")

    DeployEvents::Reconciler.call(@app)

    assert_in_delta first, e.reload.observed_at, 1.second
  end

  test "不越过应用边界" do
    other = ManagedApp.create!(name: "other", config_yaml: file_fixture("simple_deploy.yml").read,
                               destination: "production")
    theirs = DeployEvent.create!(managed_app: other, version: "aaaaaaa", source: "hook",
                                 succeeded_at: 5.minutes.ago)
    observe(version: "aaaaaaa")

    DeployEvents::Reconciler.call(@app)

    assert_nil theirs.reload.observed_at
  end

  test "没有观测时什么都不做" do
    e = event

    DeployEvents::Reconciler.call(@app)

    assert_nil e.reload.observed_at
  end
end
