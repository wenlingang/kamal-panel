require "test_helper"

class PruneObservationsJobTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(
      name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )
  end

  test "deletes observations older than the retention period" do
    Observation.create!(managed_app: @app, host: "10.0.0.1",
                        docker_status: "running", observed_at: 20.days.ago)
    Observation.create!(managed_app: @app, host: "10.0.0.1",
                        docker_status: "running", observed_at: 1.day.ago)

    PruneObservationsJob.perform_now

    assert_equal 1, Observation.where(managed_app: @app).count
  end

  test "keeps each host's latest row even when all are expired so the UI does not go blank" do
    Observation.create!(managed_app: @app, host: "10.0.0.1",
                        docker_status: "running", observed_at: 100.days.ago)
    Observation.create!(managed_app: @app, host: "10.0.0.1",
                        docker_status: "running", observed_at: 90.days.ago)

    PruneObservationsJob.perform_now

    remaining = Observation.where(managed_app: @app)

    assert_equal 1, remaining.count
    assert_in_delta 90.days.ago.to_i, remaining.first.observed_at.to_i, 60
  end

  # Note: here we can't just create one expired ProxyTarget and assert the count drops to 0 -- that
  # record is also the "most recent one" in its (app, host) group, the same rule as Observation's
  # "keep the most recent one per host even if all have expired", and it holds for ProxyTarget too
  # (otherwise it would contradict itself). So create two here, and verify that the one that is
  # truly expired and already superseded by a newer record is deleted, while the most recent one is
  # kept.
  test "prunes ProxyTarget the same way" do
    ProxyTarget.create!(managed_app: @app, host: "10.0.0.1",
                        service_name: "blog-web-production", observed_at: 20.days.ago)
    ProxyTarget.create!(managed_app: @app, host: "10.0.0.1",
                        service_name: "blog-web-production", observed_at: 1.day.ago)

    PruneObservationsJob.perform_now

    remaining = ProxyTarget.where(managed_app: @app)
    assert_equal 1, remaining.count
    assert_in_delta 1.day.ago.to_i, remaining.first.observed_at.to_i, 60
  end

  # A promise that took Task 11 two review rounds to establish: for a machine that has
  # gone unreachable, the UI falls back to its "most recent reachable" observation and
  # marks how old that data is -- never blanking the whole row (spec 6.4).
  #
  # If prune only kept the observed_at-max record per (app, host), then for a machine
  # that has been unreachable longer than the retention period, the "max" one happens to
  # be the unreachable record, while the only truly useful "last known state" that
  # last_known_rows can fall back to -- the most recent reachable observation -- is older
  # than it and would be deleted as stale data. So the machine that has been unreachable
  # longest, whose operator needs history most, would be the first to lose its history,
  # and the panel would degrade to "no history available". This regression creeps in
  # quietly over time, and no test would catch it through a "just went unreachable" scenario.
  #
  # Here we deliberately make the reachable observation much older than the retention
  # period (100 days ago) and the unreachable one also outside it (50 days ago) -- both
  # qualify to be deleted as "expired", but the reachable one must survive, because it is
  # the only fallback basis.
  # prune groups by (managed_app_id, host), not by managed_app_id alone -- if the grouping
  # scope is wrong (say it drops host, or conversely drops managed_app_id so apps trample
  # each other), the scenario of "only some hosts expired" in a multi-host app is the one
  # most likely to expose it: a wrong grouping either deletes hosts that haven't expired
  # or keeps hosts that should be deleted.
  test "with multiple hosts per app, prunes only the expired rows, judging each host independently" do
    Observation.create!(managed_app: @app, host: "10.0.0.1",
                        docker_status: "running", observed_at: 20.days.ago)
    Observation.create!(managed_app: @app, host: "10.0.0.1",
                        docker_status: "running", observed_at: 1.day.ago)

    Observation.create!(managed_app: @app, host: "10.0.0.2",
                        docker_status: "running", observed_at: 2.days.ago)

    Observation.create!(managed_app: @app, host: "10.0.0.3",
                        docker_status: "running", observed_at: 30.days.ago)

    PruneObservationsJob.perform_now

    remaining = Observation.where(managed_app: @app).order(:host)

    assert_equal %w[10.0.0.1 10.0.0.2 10.0.0.3], remaining.map(&:host).sort
    assert_equal 3, remaining.count

    host_1 = remaining.find { |o| o.host == "10.0.0.1" }
    assert_in_delta 1.day.ago.to_i, host_1.observed_at.to_i, 60,
      "The expired row should be deleted, keeping only the latest"

    host_3 = remaining.find { |o| o.host == "10.0.0.3" }
    assert_in_delta 30.days.ago.to_i, host_3.observed_at.to_i, 60,
      "The only row must be kept even when expired and not deleted by mistake because another host got mixed into the group"
  end

  test "prune keeps the row the fallback reads; a reachable row without containers cannot displace one with containers" do
    # D0: the machine is running containers normally (oldest)
    # D1: the container was removed, the machine is still reachable (newer than D0)
    # D2: the machine is fully offline (newest)
    # All three are past the retention period. The old retention condition was "newest +
    # newest reachable", which would keep D2 (newest) and D1 (newest reachable) and delete
    # D0 -- but the fallback (ManagedAppStatus#last_reachable_observation) wants the
    # "newest reachable one with containers" row, i.e. D0. Deleting it leaves the fallback
    # with nothing to land on (see final review I6).
    d0 = Observation.create!(managed_app: @app, host: "127.0.0.1", role: "web",
      container_name: "blog-web-production-aaaaaaa", version: "aaaaaaa",
      docker_status: "running", reachable: true, observed_at: 100.days.ago)
    Observation.create!(managed_app: @app, host: "127.0.0.1", role: "web",
      container_name: nil, version: nil, docker_status: nil,
      reachable: true, observed_at: 90.days.ago)
    Observation.create!(managed_app: @app, host: "127.0.0.1", role: "web",
      reachable: false, observed_at: 80.days.ago)

    PruneObservationsJob.perform_now

    assert Observation.exists?(d0.id),
      "The row the fallback will actually use (latest reachable with containers) must not be deleted by prune"

    status = ManagedAppStatus.new(@app)
    row = status.last_known_rows.find { |r| r[:host] == "127.0.0.1" }

    assert_equal "aaaaaaa", row[:version],
      "After prune the fallback must still find a landing point, rather than \"no usable historical state\""
    assert_not_nil row[:stale_since]
  end

  test "keeps the last reachable observation after a host is unreachable beyond retention so fallback still works" do
    Observation.create!(managed_app: @app, host: "127.0.0.1", role: "web",
                        container_name: "blog-web-production-aaaaaaa", version: "aaaaaaa",
                        docker_status: "running", reachable: true, observed_at: 100.days.ago)
    Observation.create!(managed_app: @app, host: "127.0.0.1", role: "web",
                        reachable: false, observed_at: 50.days.ago)

    PruneObservationsJob.perform_now

    status = ManagedAppStatus.new(@app)
    row = status.last_known_rows.find { |r| r[:host] == "127.0.0.1" }

    assert_equal "aaaaaaa", row[:version],
      "prune must not delete the only reachable historical observation available for fallback, or the longest-unreachable host loses its history first"
    assert_not_nil row[:stale_since], "The fallback state must carry how old it is and must not silently turn back into a row without a timestamp"
  end
end
