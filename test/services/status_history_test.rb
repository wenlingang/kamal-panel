require "test_helper"

class StatusHistoryTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("two_host_deploy.yml").read,
                              destination: "production")
    @now = Time.current.change(usec: 0)
  end

  # One collection round: every host's rows share one observed_at, like ContainerCollector writes.
  def round(at, hosts = { "10.0.0.1" => "aaaaaaa", "10.0.0.2" => "aaaaaaa" }, health: nil, reachable: true)
    hosts.each do |host, version|
      Observation.create!(managed_app: @app, host:, role: "web", version:, health:, reachable:,
                          container_name: version && "blog-web-production-#{version}",
                          docker_status: version && "running", observed_at: at)
    end
  end

  test "pads short history with placeholders on the left, oldest round first" do
    round(@now - 2.minutes)
    round(@now - 1.minute)

    cells = StatusHistory.new(@app, rounds: 5).cells

    assert_equal 5, cells.size
    assert_equal [ true, true, true, false, false ], cells.map(&:placeholder?)
    assert_equal [ @now - 2.minutes, @now - 1.minute ], cells.last(2).map(&:observed_at)
  end

  test "groups rows by round, so two hosts in one round make one cell" do
    round(@now)

    assert_equal 1, StatusHistory.new(@app, rounds: 3).recorded_cells.size
  end

  test "colours each round by its own level" do
    round(@now - 3.minutes)
    round(@now - 2.minutes, { "10.0.0.1" => "aaaaaaa", "10.0.0.2" => "bbbbbbb" })
    round(@now - 1.minute, health: "unhealthy")
    round(@now, { "10.0.0.1" => "aaaaaaa", "10.0.0.2" => nil }, reachable: false)

    levels = StatusHistory.new(@app, rounds: 4).cells.map(&:level)

    assert_equal %i[ok drift unhealthy unreachable], levels
  end

  test "keeps only the newest rounds" do
    5.times { |i| round(@now - i.minutes) }

    cells = StatusHistory.new(@app, rounds: 3).cells

    assert_equal 3, cells.size
    assert_equal [ @now - 2.minutes, @now - 1.minute, @now ], cells.map(&:observed_at)
  end

  test "a past round is not called stale just because it is old" do
    round(3.days.ago.change(usec: 0))

    assert_equal [ :ok ], StatusHistory.new(@app, rounds: 1).cells.map(&:level)
  end

  test "counts the recorded rounds that were not ok" do
    round(@now - 1.minute, health: "unhealthy")
    round(@now)

    assert_equal 1, StatusHistory.new(@app, rounds: 10).problem_count
  end

  test "renders history for an app whose config no longer parses" do
    round(@now)
    @app.update_columns(config_yaml: "service: [", last_poll_error: "boom",
                        last_poll_error_at: @now, first_poll_error_at: @now)

    assert_equal [ :ok ], StatusHistory.new(@app.reload, rounds: 1).cells.map(&:level)
  end

  test "reads history in one query" do
    3.times { |i| round(@now - i.minutes) }
    history = StatusHistory.new(@app)

    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { history.cells }

    assert_equal 1, queries
  end

  test "words a round of unreadable output as such, not as an unreachable host" do
    Observation.create!(managed_app: @app, host: "10.0.0.1", reachable: false, observed_at: @now,
                        error: Collectors::ContainerCollector.unparseable_output_error(3))

    cell = StatusHistory.new(@app, rounds: 1).cells.last

    assert_equal :unreachable, cell.level
    assert_equal "unparseable", cell.badge_key
  end
end
