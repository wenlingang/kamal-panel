require "test_helper"

class ObservationTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(
      name: "blog",
      config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )
  end

  test "Observation cannot be updated" do
    observation = Observation.create!(
      managed_app: @app, host: "10.0.0.1", docker_status: "running",
      observed_at: Time.current
    )

    assert_raises(ActiveRecord::ReadOnlyRecord) do
      observation.update!(docker_status: "exited")
    end
  end
end
