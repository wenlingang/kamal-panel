require "test_helper"

class Alerting::LogScanTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # Stands in for LogQuery: returns a canned Result, no SSH.
  FakeQuery = Struct.new(:result) do
    def call = result
  end

  setup do
    Rails.cache.clear
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production")
    @rule = AlertRule.create!(name: "ERROR", condition: "log_keyword", keyword: "ERROR", window_minutes: 5, threshold: 3,
                              for_minutes: 0)
    @now = Time.current
  end

  def result(matches:, errors: [], hosts: [ "127.0.0.1" ])
    entries = Array.new(matches) { |i| LogQuery::Entry.new(time: @now, host: "127.0.0.1", source: "web", line: "ERROR #{i}", level: :error) }
    LogQuery::Result.new(entries:, errors:, hosts:, truncated: false, duration_ms: 5, cursor: @now, boundary_keys: [])
  end

  def scan(r) = Alerting::LogScan.call(@rule, @app, now: @now, query: FakeQuery.new(r))
  def host_error(host) = LogQuery::HostError.new(host:, kind: :unreachable, detail: "timeout")

  test "matches at the threshold fire; fewer resolve" do
    assert scan(result(matches: 3))
    event = AlertEvent.sole
    assert_predicate event, :firing?
    assert_includes event.message, "3"

    @now += 5.minutes
    scan(result(matches: 1))
    assert_predicate event.reload, :resolved?
  end

  test "when no host could be read nothing changes and the rule says why" do
    scan(result(matches: 3))
    event = AlertEvent.sole

    @now += 5.minutes
    assert_not scan(result(matches: 0, errors: [ host_error("127.0.0.1") ]))

    assert_predicate event.reload, :firing?, "unreadable logs are not zero hits"
    assert_includes @rule.reload.last_error, "timeout"
  end

  test "no credential (host nil) counts as all hosts failing" do
    assert_not scan(result(matches: 0, errors: [ LogQuery::HostError.new(host: nil, kind: :no_credential, detail: nil) ], hosts: []))

    assert_equal 0, AlertEvent.count
  end

  test "with some hosts unreadable, a low count can't clear the alert" do
    scan(result(matches: 3, hosts: %w[a b]))
    event = AlertEvent.sole

    scan(result(matches: 0, errors: [ host_error("b") ], hosts: %w[a b]))

    assert_predicate event.reload, :firing?
  end

  test "a clean scan clears the recorded error" do
    @rule.record_error!("old trouble")

    scan(result(matches: 0))

    assert_nil @rule.reload.last_error
  end

  test "without a fake query it runs the real LogQuery" do
    # No SSH credential: LogQuery answers with a no_credential error, so nothing changes.
    assert_not Alerting::LogScan.call(@rule, @app, now: @now)
    assert_equal 0, AlertEvent.count
  end
end
