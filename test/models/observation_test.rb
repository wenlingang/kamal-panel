require "test_helper"

class ObservationTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(
      name: "blog",
      config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )
  end

  test "Observation 不可更新" do
    observation = Observation.create!(
      managed_app: @app, host: "10.0.0.1", docker_status: "running",
      observed_at: Time.current
    )

    assert_raises(ActiveRecord::ReadOnlyRecord) do
      observation.update!(docker_status: "exited")
    end
  end

  test "latest_for 只返回每台主机最近一轮" do
    old_time = 10.minutes.ago
    new_time = Time.current

    Observation.create!(managed_app: @app, host: "10.0.0.1", version: "old",
                        docker_status: "running", observed_at: old_time)
    Observation.create!(managed_app: @app, host: "10.0.0.1", version: "new",
                        docker_status: "running", observed_at: new_time)
    Observation.create!(managed_app: @app, host: "10.0.0.2", version: "other",
                        docker_status: "running", observed_at: new_time)

    versions = Observation.latest_for(@app).pluck(:version).sort

    assert_equal %w[new other], versions
  end
end
