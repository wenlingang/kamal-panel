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

  test "the first convergence only writes a baseline and creates no event" do
    converge(version: "aaaaaaa")

    DeployEvents::Inferrer.call(@managed_app)

    assert_equal 0, @managed_app.deploy_events.count,
                 "a newly onboarded app has long been running this version; it was not deployed today"
    assert_equal "aaaaaaa", @managed_app.reload.last_converged_version
    assert_predicate @managed_app.last_converged_at, :present?
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

  test "mixed versions are not convergence: no event and no state change" do
    converge(version: "aaaaaaa", at: 10.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)

    # Mid rolling deploy: one machine is already on the new version, the other hasn't switched yet
    observe(host: "10.0.0.1", version: "bbbbbbb")
    observe(host: "10.0.0.2", version: "aaaaaaa")
    DeployEvents::Inferrer.call(@managed_app)

    assert_equal 0, @managed_app.deploy_events.count
    assert_equal "aaaaaaa", @managed_app.reload.last_converged_version
  end

  test "an unreachable host prevents convergence" do
    converge(version: "aaaaaaa", at: 10.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)

    observe(host: "10.0.0.1", version: "bbbbbbb")
    observe(host: "10.0.0.2", version: nil, status: nil, reachable: false)
    DeployEvents::Inferrer.call(@managed_app)

    assert_equal 0, @managed_app.deploy_events.count,
                 "the unreachable host may still run the old version and the panel cannot know"
    assert_equal "aaaaaaa", @managed_app.reload.last_converged_version
  end

  test "no running observation at all is not convergence" do
    HOSTS.each { |host| observe(host: host, version: "aaaaaaa", status: "exited") }

    DeployEvents::Inferrer.call(@managed_app)

    assert_equal 0, @managed_app.deploy_events.count
    assert_nil @managed_app.reload.last_converged_version
  end

  test "repeated rounds of the same version are idempotent" do
    converge(version: "aaaaaaa", at: 10.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)
    converge(version: "bbbbbbb", at: 5.minutes.ago)

    3.times { DeployEvents::Inferrer.call(@managed_app) }

    assert_equal 1, @managed_app.deploy_events.count,
                 "polling runs every 2 seconds during a burst; without idempotency the same deploy would flood the history"
  end

  test "a rollback to a much older version is still recorded" do
    # That version was deployed three months ago, and an old hook event is sitting in the DB
    old_event = DeployEvent.create!(managed_app: @managed_app, version: "aaaaaaa",
                                    source: "hook", succeeded_at: 3.months.ago,
                                    observed_at: 3.months.ago, created_at: 3.months.ago)
    converge(version: "bbbbbbb", at: 10.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)

    # Now rolling back to aaaaaaa
    converge(version: "aaaaaaa", at: 1.minute.ago)
    DeployEvents::Inferrer.call(@managed_app)

    inferred = @managed_app.deploy_events.where(source: "inferred", version: "aaaaaaa")
    assert_equal 1, inferred.count,
                 "deduplicating by version alone would swallow this rollback -- it is a real deploy"
    refute_equal old_event.id, inferred.sole.id
  end

  test "stale observations from hosts outside the config do not block convergence permanently" do
    converge(version: "aaaaaaa", at: 10.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)

    # 10.0.0.9 was removed from deploy.yml long ago, but its observation row was deliberately kept,
    # and it runs an old version that doesn't match the current converged version.
    observe(host: "10.0.0.9", version: "zzzzzzz", at: 10.minutes.ago)
    converge(version: "bbbbbbb", at: 1.minute.ago)
    DeployEvents::Inferrer.call(@managed_app)

    event = @managed_app.deploy_events.sole
    assert_equal "bbbbbbb", event.version
    assert_equal "inferred", event.source
    assert_equal "bbbbbbb", @managed_app.reload.last_converged_version
  end

  test "differing versions across roles on one host are not convergence" do
    converge(version: "aaaaaaa", at: 10.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)

    at = 1.minute.ago
    observe(host: "10.0.0.1", version: "bbbbbbb", at: at, role: "web")
    observe(host: "10.0.0.1", version: "aaaaaaa", at: at, role: "worker")
    observe(host: "10.0.0.2", version: "bbbbbbb", at: at, role: "web")
    DeployEvents::Inferrer.call(@managed_app)

    assert_equal 0, @managed_app.deploy_events.count
    assert_equal "aaaaaaa", @managed_app.reload.last_converged_version
  end

  test "yields to an existing same-version hook event in the convergence window, but still updates state" do
    converge(version: "aaaaaaa", at: 30.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)

    # The hook reported this version, and then the panel observed convergence
    DeployEvent.create!(managed_app: @managed_app, version: "bbbbbbb", source: "hook",
                        succeeded_at: 2.minutes.ago)
    converge(version: "bbbbbbb", at: 1.minute.ago)
    DeployEvents::Inferrer.call(@managed_app)

    assert_equal 0, @managed_app.deploy_events.where(source: "inferred").count
    assert_equal "bbbbbbb", @managed_app.reload.last_converged_version,
                 "yielding records no event, but state must still update, otherwise the next change is compared against the wrong time boundary"
  end
end
