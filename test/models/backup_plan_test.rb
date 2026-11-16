require "test_helper"

class BackupPlanTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("accessory_deploy.yml").read, destination: "production")
    @destination = BackupDestination.create!(name: "s3", endpoint: "https://s3.example.com", bucket: "backups",
                                             access_key_id: "key", secret_access_key: "secret")
  end

  test "knows which images hold a database it can dump" do
    assert_equal "postgres", BackupPlan.engine_for_image("postgres:16")
    assert_equal "postgres", BackupPlan.engine_for_image("ghcr.io/x/postgis:3")
    assert_equal "mysql", BackupPlan.engine_for_image("mariadb:11")
    assert_nil BackupPlan.engine_for_image("redis:7")
    assert_equal [ { name: "db", engine: "postgres", image: "postgres:16" } ], BackupPlan.candidates(@app)
  end

  test "only an accessory deploy.yml declares, with a sane database name" do
    plan = @app.backup_plans.new(accessory: "nope", engine: "postgres", backup_destination: @destination)
    assert_not plan.valid?
    assert plan.errors.of_kind?(:accessory, :inclusion)

    plan = @app.backup_plans.new(accessory: "db", engine: "postgres", database: "x; rm -rf /", backup_destination: @destination)
    assert_not plan.valid?
    assert plan.errors.of_kind?(:database, :invalid)
  end

  test "a new plan is due at once, and only one tick claims it" do
    plan = @app.backup_plans.create!(accessory: "db", engine: "postgres", backup_destination: @destination, every_hours: 6)
    now = Time.current
    assert_includes BackupPlan.due(now + 1.second), plan

    stale = BackupPlan.find(plan.id)
    assert plan.claim_due!(now)
    assert_not stale.claim_due!(now), "an overlapping tick holding the old next_run_at loses"
    assert_in_delta now + 6.hours, plan.next_run_at, 1
  end

  test "dump and restore commands use the container's own credentials" do
    plan = @app.backup_plans.new(accessory: "db", engine: "postgres", backup_destination: @destination)
    command = BackupRunner.dump_command(plan)

    assert command.start_with?("docker exec blog-db sh -c ")
    assert_includes command, "pg_dump"
    assert_includes command, "POSTGRES_PASSWORD"
    assert_includes BackupRunner.restore_command(plan), "docker exec -i blog-db"
  end
end
