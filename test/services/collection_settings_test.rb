require "test_helper"

class CollectionSettingsTest < ActiveSupport::TestCase
  def build(overrides = {}) = CollectionSettings.new(CollectionSettings.defaults.deep_merge(overrides.deep_stringify_keys))

  test "the built-in defaults load and validate" do
    settings = CollectionSettings.load(env: {})

    assert_equal 5.seconds, settings.status_tick
    assert_equal 60.seconds, settings.status_idle
    assert_equal 30.seconds, settings.alerts_every
    assert settings.for_host("10.0.0.1").containers
  end

  test "an override file is deep-merged, and environment variables win over it" do
    Tempfile.create([ "collection", ".yml" ]) do |file|
      file.write({ "status" => { "idle" => 120 }, "metrics" => { "containers" => false } }.to_yaml)
      file.flush

      settings = CollectionSettings.load(env: { "COLLECTION_CONFIG" => file.path, "COLLECTION_STATUS_IDLE" => "300" })

      assert_equal 300.seconds, settings.status_idle, "ENV beats the override file"
      refute settings.for_host("10.0.0.1").containers, "the override file beats the defaults"
      assert_equal 10.seconds, settings.status_viewing, "keys the override leaves out keep their default"
    end
  end

  test "a host override applies to that host only" do
    settings = build(hosts: { "10.0.0.5" => { metrics: { every: 5, containers: false }, status: { proxy: false } } })

    busy = settings.for_host("10.0.0.5")
    other = settings.for_host("10.0.0.6")
    assert_equal [ false, 5, false ], [ busy.containers, busy.metrics_every, busy.proxy ]
    assert_equal [ true, 1, true ], [ other.containers, other.metrics_every, other.proxy ]
  end

  test "a host sampled every N minutes is due on clock-aligned minutes only" do
    host = build(hosts: { "10.0.0.5" => { metrics: { every: 5 } } }).for_host("10.0.0.5")

    assert host.metrics_due?(Time.zone.parse("2026-11-08 10:05:00"))
    refute host.metrics_due?(Time.zone.parse("2026-11-08 10:06:00"))
    refute build(metrics: { enabled: false }).for_host("x").metrics_due?(Time.zone.parse("2026-11-08 10:05:00"))
  end

  test "typos and out-of-range values stop loading with a message naming them" do
    {
      { status: { idel: 60 } } => "idel",
      { status: { tick: 10, burst: 5 } } => "tick ≤ burst",
      { metrics: { every: 0 } } => "metrics.every",
      { metrics: { containers: "no" } } => "metrics.containers",
      { hosts: { "10.0.0.5" => { status: { idle: 5 } } } } => "不能覆盖 idle",
      { hosts: { "10.0.0.5" => { alerts: { every: 60 } } } } => "不能覆盖 alerts"
    }.each do |overrides, message|
      error = assert_raises(CollectionSettings::Error, overrides.inspect) { build(overrides) }
      assert_includes error.message, message
    end
  end

  test "a COLLECTION_CONFIG pointing nowhere is an error, not a silent fallback" do
    assert_raises(CollectionSettings::Error) { CollectionSettings.load(env: { "COLLECTION_CONFIG" => "/nonexistent.yml" }) }
  end
end
