require "test_helper"

class DeployEvents::IngestTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  def ingest(phase, version: "aaaaaaa", performer: "ci", command: "deploy",
             recorded_at: Time.current)
    DeployEvents::Ingest.call(
      managed_app: @app, phase: phase,
      attributes: { version: version, performer: performer, command: command,
                    recorded_at: recorded_at }
    )
  end

  test "post-deploy completes the same attempt instead of creating a new row" do
    started = ingest("started")[:event]
    result = ingest("succeeded")

    assert_equal started.id, result[:event].id
    assert result[:changed]
    assert_predicate result[:event].succeeded_at, :present?
    assert_equal 1, DeployEvent.count
  end
end
