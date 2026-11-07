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
end
