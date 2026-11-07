require "test_helper"

class ManagedAppStatusTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear # cached_app_hosts cache key contains the id, and SQLite may reuse ids after rollback

    # Both machines (10.0.0.1, 10.0.0.2) are configured in deploy.yml -- so that the hosts observe()
    # uses line up with "which machines are actually in the config", making it possible to test the
    # machine that is "in the config but never collected".
    @app = ManagedApp.create!(
      name: "blog", config_yaml: file_fixture("two_host_deploy.yml").read,
      destination: "production"
    )
    @now = Time.current
  end

  def observe(host:, version: nil, docker_status: "running", health: nil, reachable: true,
              role: "web", observed_at: @now)
    Observation.create!(
      managed_app: @app, host: host, role: role,
      container_name: version && "blog-#{role}-production-#{version}",
      version: version, docker_status: docker_status, health: health,
      reachable: reachable, observed_at: observed_at
    )
  end

  # A machine that is reachable but matched no container -- docker_status/version/ container_name
  # are all nil, which is exactly the shape Collectors::ContainerCollector writes when "docker ps
  # found no matching container" (its empty_row has only base_row: host/reachable/observed_at, no
  # other fields). A specially named helper rather than having callers assemble `version: nil,
  # docker_status: nil` themselves, because the original test suite never wrote out this shape --
  # the helper's defaults quietly made it an inexpressible state, which is one of the reasons this
  # missed-detection bug stayed hidden until review.
  def observe_no_containers(host:, reachable: true)
    observe(host: host, version: nil, docker_status: nil, reachable: reachable)
  end

  test "is ok when all hosts agree on version and are running" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", version: "aaaaaaa")

    status = ManagedAppStatus.new(@app)

    assert_equal :ok, status.level
    refute status.drift?
  end

  test "is drift when hosts differ in version, with the highest priority" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", version: "bbbbbbb")

    status = ManagedAppStatus.new(@app)

    assert_equal :drift, status.level
    assert status.drift?
    assert_equal %w[aaaaaaa bbbbbbb], status.versions.sort
  end

  test "a lost host yields unreachable" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", reachable: false)

    assert_equal :unreachable, ManagedAppStatus.new(@app).level
  end

  test "never shows ok when data is stale: the 3-second-glance badge must not render 'I could not look' as 'all good'" do
    observe(host: "10.0.0.1", version: "aaaaaaa", observed_at: @now - 1.hour)
    observe(host: "10.0.0.2", version: "aaaaaaa", observed_at: @now - 1.hour)

    status = ManagedAppStatus.new(@app)

    assert status.stale?
    refute_equal :ok, status.level,
      "When all observations are 1 hour old, level must not be :ok; a polling stall must be visible on the overview badge (see final review C1)"
    assert_equal :unreachable, status.level,
      "Stale and unreachable share the same yellow tier; no sixth state is added (see ManagedAppStatus#level comment)"
  end
end
