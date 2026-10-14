require "test_helper"

class Demo::SeederTest < ActiveSupport::TestCase
  setup { Rails.cache.clear }

  def seed = capture_io { Demo::Seeder.new(users(:two)).call }
  def refresh = capture_io { Demo::Seeder.new.refresh }

  def app(name) = ManagedApp.find_by!(name:)
  def status(name) = ManagedAppStatus.new(app(name))

  # Each demo app exists to show one state; if the data drifts, the demo shows the wrong thing.
  def assert_scenarios
    assert_equal :ok, status("demo-shop").level
    assert_equal :drift, status("demo-blog").level
    assert_equal :unhealthy, status("demo-api").level
    assert_equal "unreachable", status("demo-jobs").badge_key
    assert_equal "stale", status("demo-legacy").badge_key
    assert_equal :unknown, status("demo-fresh").level
    assert_predicate app("demo-archive"), :deactivated?
  end

  test "seeding creates one app per state the UI distinguishes" do
    seed

    assert_equal Demo::Seeder::APPS.keys.sort, Demo::Seeder.apps.pluck(:name).sort
    assert_scenarios
  end

  test "a month later, refresh brings every scenario back as of now and leaves the audit alone" do
    seed

    travel 30.days do
      audit_count = AuditLog.count
      Rails.cache.clear

      refresh

      assert_scenarios
      assert_equal audit_count, AuditLog.count
    end
  end

  test "refresh undoes a real poll that overwrote a scenario with SSH errors" do
    seed
    Observation.create!(managed_app: app("demo-api"), host: "10.1.0.31", reachable: false,
                        error: "Net::SSH::Disconnect: connection closed", observed_at: 1.second.from_now)
    assert_equal "unreachable", status("demo-api").badge_key

    refresh

    assert_equal :unhealthy, status("demo-api").level
  end

  test "refresh adds scenarios that an older demo set doesn't have yet" do
    seed
    %w[demo-legacy demo-archive].each do |name| # as if seeded before these scenarios existed
      Observation.where(managed_app: app(name)).delete_all
      ProxyTarget.where(managed_app: app(name)).delete_all
      app(name).destroy!
    end

    refresh

    assert_scenarios
  end

  test "refresh without any demo data says to seed first" do
    error = assert_raises(ArgumentError) { Demo::Seeder.new.refresh }
    assert_includes error.message, "demo:seed"
  end
end
