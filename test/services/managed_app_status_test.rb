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

  test "version drift takes priority over container anomalies" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", version: "bbbbbbb", docker_status: "exited")

    assert_equal :drift, ManagedAppStatus.new(@app).level
  end

  test "stopped old versions do not count toward drift detection" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.1", version: "0000000", docker_status: "exited")
    observe(host: "10.0.0.2", version: "aaaaaaa")

    assert_equal :ok, ManagedAppStatus.new(@app).level
  end

  test "multiple roles on the same host with the same version do not count as drift" do
    observe(host: "10.0.0.1", role: "web", version: "aaaaaaa")
    observe(host: "10.0.0.1", role: "worker", version: "aaaaaaa")
    observe(host: "10.0.0.2", role: "web", version: "aaaaaaa")
    observe(host: "10.0.0.2", role: "worker", version: "aaaaaaa")

    assert_equal :ok, ManagedAppStatus.new(@app).level
  end

  test "unhealthy container yields unhealthy" do
    observe(host: "10.0.0.1", version: "aaaaaaa", health: "unhealthy")
    observe(host: "10.0.0.2", version: "aaaaaaa")

    assert_equal :unhealthy, ManagedAppStatus.new(@app).level
  end

  test "a lost host yields unreachable" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", reachable: false)

    assert_equal :unreachable, ManagedAppStatus.new(@app).level
  end

  # Critical: if a reachable machine matched no container at all (never deployed, or the container
  # was deleted entirely), it must not fall to :ok -- that looks exactly like "everything is fine",
  # while in reality it is "this machine isn't serving at all".
  test "a reachable host with no matching container is unhealthy, not ok" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe_no_containers(host: "10.0.0.2")

    assert_equal :unhealthy, ManagedAppStatus.new(@app).level
  end

  test "is also unhealthy when all hosts are reachable but none match a container" do
    observe_no_containers(host: "10.0.0.1")
    observe_no_containers(host: "10.0.0.2")

    assert_equal :unhealthy, ManagedAppStatus.new(@app).level
  end

  # Important: a machine configured in deploy.yml but with no Observation ever must not be quietly
  # ignored by the status computation -- that is "never looked at" being treated as "looked at, no
  # problem".
  test "a host in the config that was never polled is not ok and counts as a lost host" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    # 10.0.0.2 is configured in two_host_deploy.yml, but here we deliberately write no
    # Observation for it -- simulating "a newly added machine whose turn to be collected hasn't
    # come" or "the data was cleaned up".

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

  test "unknown when never polled" do
    assert_equal :unknown, ManagedAppStatus.new(@app).level
  end

  test "every status has a text label, not just color" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", version: "aaaaaaa")

    assert_predicate ManagedAppStatus.new(@app).label, :present?
  end

  # Important: data age must come from the batch of observations being displayed, not from "when the
  # latest collection in the database is right now" -- otherwise polling would produce the
  # self-contradiction of "the data age shown on the page is newer than the actual time of the other
  # data on the page".
  test "data age comes from the already-loaded observations, not from a re-queried updated time" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", version: "aaaaaaa")
    status = ManagedAppStatus.new(@app)

    assert_equal :ok, status.level # triggers and caches this batch of observations

    # Simulate "a newer collection round arrived after the page was rendered" -- if #observed_at
    # re-queried the DB, it would return this newer time rather than the time of the batch of data
    # actually displayed on the page.
    observe(host: "10.0.0.1", version: "aaaaaaa", observed_at: @now + 1.hour)

    assert_equal @now.to_i, status.observed_at.to_i
  end

  # Important (review round 2): the only honest wording for the data-age line is "no data here is
  # older than N". If we took the latest machine's time, a machine not collected for 3 hours would
  # be masked by the timestamp of a machine collected 12 seconds ago -- exactly the one direction in
  # which the data-age indicator must never lie: making people think the whole page's data is fresh.
  test "data age uses the oldest host, not the newest" do
    observe(host: "10.0.0.1", version: "aaaaaaa", observed_at: @now - 3.hours)
    observe(host: "10.0.0.2", version: "aaaaaaa", observed_at: @now)

    status = ManagedAppStatus.new(@app)

    assert_equal (@now - 3.hours).to_i, status.observed_at.to_i,
      "Must report the age of the oldest host; using the newest would hide "\
      "'not polled for 3 hours' behind '12 seconds ago'"
  end

  # Important (review round 2): if an unreachable machine has no "reachable" historical observation
  # at all, last_known_rows has no "last time" to fall back to -- this is the branch most likely to
  # let a blank row slip onto the UI, and it must be verified to honestly stay "unreachable, no
  # history", rather than quietly inventing a version, or clearing the whole row.
  test "an unreachable host that never had a reachable observation stays unreachable and no historical version is invented" do
    observe(host: "10.0.0.1", reachable: false, version: nil, docker_status: nil)
    observe(host: "10.0.0.2", version: "aaaaaaa")

    status = ManagedAppStatus.new(@app)
    row = status.last_known_rows.find { |r| r[:host] == "10.0.0.1" }

    assert_equal false, row[:reachable]
    assert_nil row[:version], "A version number must not be invented when there is no historical state to fall back on"
    assert_nil row[:stale_since], "A fake \"last seen\" timestamp must not appear when there is no historical state"
  end

  # Important (review round 2): when both machines have appeared and one is unreachable, the
  # fallback must use only its own history. If the fallback logic missed the host filter, it would
  # read "the most recent globally reachable observation" -- possibly another machine's version, and
  # the panel would show B's version under A's name, which is more dangerous than blank.
  test "an unreachable host's fallback state uses only its own history and does not leak from another host" do
    observe(host: "10.0.0.1", version: "aaaaaaa", observed_at: @now)
    observe(host: "10.0.0.2", version: "bbbbbbb", observed_at: @now)

    # 10.0.0.1 goes unreachable afterwards
    observe(host: "10.0.0.1", version: nil, docker_status: nil, reachable: false,
            observed_at: @now + 1.minute)

    status = ManagedAppStatus.new(@app)
    row = status.last_known_rows.find { |r| r[:host] == "10.0.0.1" }

    assert_equal "aaaaaaa", row[:version],
      "An unreachable host's fallback must use its own last reachable record and must not read another host's version"
    refute_equal "bbbbbbb", row[:version]
  end

  # Minor (review round 2, a judgment call): a machine that was collected once but is no longer in
  # the current deploy.yml -- don't delete the row (deleting would quietly discard the information
  # "it once existed"), but it must never keep showing "ok" unconditionally, which would be the
  # panel vouching for a machine that no longer belongs to this app. This verifies host_rows can
  # distinguish "still in the config" from "removed from the config".
  test "a host polled before but removed from the current config still appears in host_rows, marked as not in config" do
    app = ManagedApp.create!(
      name: "blog-#{SecureRandom.hex(4)}", config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )

    Observation.create!(managed_app: app, host: "127.0.0.1", role: "web",
      container_name: "blog-web-production-aaaaaaa", version: "aaaaaaa",
      docker_status: "running", reachable: true, observed_at: @now)
    # "10.9.9.9" was collected once, but simple_deploy.yml never configured it --
    # simulating "this machine was later deleted from deploy.yml".
    Observation.create!(managed_app: app, host: "10.9.9.9", role: "web",
      container_name: "blog-web-production-zzzzzzz", version: "zzzzzzz",
      docker_status: "running", reachable: true, observed_at: @now)

    status = ManagedAppStatus.new(app)
    rows = status.host_rows.index_by { |r| r[:host] }

    assert rows["127.0.0.1"][:configured]
    refute rows["10.9.9.9"][:configured],
      "A host no longer in deploy.yml must not be treated as an ordinary row that \"still belongs to this app\""
  end

  # Important (review round 3, underestimate): if data age looks only at the oldest value among the
  # records of #observations, a machine that is configured but never collected becomes completely
  # invisible -- it contributes no timestamp to the "data age" computation, so the indicator may say
  # "just collected", while actually there is a machine the panel never looked at at all. A machine
  # never looked at is "oldest", not "nonexistent".
  test "the data-age indicator must not show fresh when a configured host was never polled" do
    observe(host: "10.0.0.1", version: "aaaaaaa", observed_at: @now)
    # 10.0.0.2 is configured in two_host_deploy.yml, but we deliberately write no Observation.

    status = ManagedAppStatus.new(@app)

    assert status.stale?,
      "When a configured host has no observation at all, the indicator must not show 'fresh'; nothing is known about this host, " \
      "which is a completely different thing from 'all hosts are recent'"
  end

  # Important (review round 3, overestimate): if data age isn't filtered by "which machines are in
  # the current config", a machine removed from deploy.yml but collected historically would forever
  # drag its old timestamp along (Observations are append-only and don't vanish when config
  # changes), pinning the whole app at "stale" -- a "cry wolf" regression: the indicator is always
  # red, and operators learn to stop looking at it.
  test "the data-age indicator must not show stale when the only laggard is a host no longer in the config" do
    app = ManagedApp.create!(
      name: "blog-#{SecureRandom.hex(4)}", config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )

    Observation.create!(managed_app: app, host: "127.0.0.1", role: "web",
      container_name: "blog-web-production-aaaaaaa", version: "aaaaaaa",
      docker_status: "running", reachable: true, observed_at: @now)
    # "10.9.9.9" isn't in simple_deploy.yml, but a very old historical observation is kept --
    # simulating "this machine was decommissioned long ago and removed from the config".
    Observation.create!(managed_app: app, host: "10.9.9.9", role: "web",
      container_name: "blog-web-production-zzzzzzz", version: "zzzzzzz",
      docker_status: "running", reachable: true, observed_at: @now - 3.hours)

    status = ManagedAppStatus.new(app)

    refute status.stale?,
      "When the only over-age contributor is a host no longer in the config, the indicator must not show 'expired'; " \
      "it is already called out by the decommission banner and should not drag down this global number"
  end

  # Regression guard: when all configured machines' data is fresh, it must still show fresh -- to
  # prevent the two fixes above from overcorrecting and blocking the "fresh" path too.
  test "when the proxy status cannot be read, takes traffic must be unknown (nil), not invented as 'no'" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    # No ProxyTarget was created for this machine -- the panel never asked about proxy status at
    # all.

    status = ManagedAppStatus.new(@app)
    row = status.host_rows.find { |r| r[:host] == "10.0.0.1" }

    assert_nil row[:routed],
      "When the panel could not ask kamal-proxy, 'takes traffic' must be unknown and not rendered as a definite 'no' (see final review I2)"
  end

  test "takes traffic is likewise unknown when the host's latest ProxyTarget is unreachable" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    ProxyTarget.create!(managed_app: @app, host: "10.0.0.1", reachable: false,
      error: "连接被拒绝", observed_at: @now)

    status = ManagedAppStatus.new(@app)
    row = status.host_rows.find { |r| r[:host] == "10.0.0.1" }

    assert_nil row[:routed]
  end

  test "takes traffic is a definite true/false when a route table is actually obtained" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    ProxyTarget.create!(managed_app: @app, host: "10.0.0.1", service_name: "blog-web-production",
      target: "blog-web-production-aaaaaaa:80", observed_at: @now)

    status = ManagedAppStatus.new(@app)
    row = status.host_rows.find { |r| r[:host] == "10.0.0.1" }

    assert_equal true, row[:routed]
  end

  test "stale threshold equals three times the idle polling interval, not a hardcoded constant" do
    assert_equal PollCadence::IDLE * 3, ManagedAppStatus.stale_threshold
  end

  test "stale threshold follows PollCadence::IDLE, proving it is derived and not hardcoded" do
    original = PollCadence::IDLE
    silence_warnings { PollCadence.const_set(:IDLE, 10.minutes) }

    assert_equal 30.minutes, ManagedAppStatus.stale_threshold
  ensure
    silence_warnings { PollCadence.const_set(:IDLE, original) }
  end

  test "data-age indicator shows fresh when all configured hosts have fresh data" do
    observe(host: "10.0.0.1", version: "aaaaaaa", observed_at: @now)
    observe(host: "10.0.0.2", version: "aaaaaaa", observed_at: @now)

    status = ManagedAppStatus.new(@app)

    refute status.stale?
  end
end
