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

  test "pre-deploy creates a row and sets only started_at" do
    result = ingest("started")

    assert result[:changed]
    assert_predicate result[:event].started_at, :present?
    assert_nil result[:event].succeeded_at
    assert_equal "hook", result[:event].source
  end

  test "post-deploy completes the same attempt instead of creating a new row" do
    started = ingest("started")[:event]
    result = ingest("succeeded")

    assert_equal started.id, result[:event].id
    assert result[:changed]
    assert_predicate result[:event].succeeded_at, :present?
    assert_equal 1, DeployEvent.count
  end

  test "when pre is lost and post arrives first, creates a row with only succeeded_at" do
    result = ingest("succeeded")

    assert_nil result[:event].started_at
    assert_predicate result[:event].succeeded_at, :present?
  end

  test "a duplicate pre-deploy creates no new row and is not a state change" do
    ingest("started")
    result = ingest("started")

    assert_equal 1, DeployEvent.count
    refute result[:changed], "a duplicate report should not trigger another burst poll"
  end

  test "deploying the same version twice yields two rows" do
    ingest("started")
    ingest("succeeded")
    ingest("started")

    assert_equal 2, DeployEvent.count
  end

  test "pairing does not cross apps" do
    other = ManagedApp.create!(name: "other", config_yaml: file_fixture("simple_deploy.yml").read,
                               destination: "production")
    DeployEvents::Ingest.call(managed_app: other, phase: "started",
                              attributes: { version: "aaaaaaa", performer: "ci",
                                            command: "deploy", recorded_at: Time.current })

    ingest("succeeded")

    assert_equal 2, DeployEvent.count
    assert_nil other.deploy_events.sole.succeeded_at
  end

  test "a duplicate post-deploy creates no new row and is not a state change" do
    ingest("started")
    ingest("succeeded")
    result = ingest("succeeded")

    assert_equal 1, DeployEvent.count
    refute result[:changed], "a duplicate succeeded report should not trigger another burst poll"
  end

  test "a same-version post outside the dedup window still creates a new row" do
    ingest("started")
    first = ingest("succeeded")[:event]
    # Move the previous row's succeeded_at outside the window, simulating "a retry that arrives much
    # later", rather than really waiting 1 minute -- so the test needs no sleep and doesn't depend
    # on assumptions about travel's current instant.
    first.update!(succeeded_at: (DeployEvents::Ingest::DUPLICATE_WINDOW + 1.second).ago)

    result = ingest("succeeded")

    assert_equal 2, DeployEvent.count
    assert result[:changed]
    refute_equal first.id, result[:event].id
  end

  test "an unfinished same-version row from 3 hours ago no longer looks like the same deploy, so a new pre skips it" do
    stale = ingest("started")[:event]
    stale.update!(started_at: 3.hours.ago)

    result = ingest("started")

    assert result[:changed]
    refute_equal stale.id, result[:event].id
    assert_equal 2, DeployEvent.count
  end

  test "a slow but normal deploy -- a succeeded arriving 16 minutes after pre still pairs with the same row" do
    started = ingest("started")[:event]
    started.update!(started_at: 16.minutes.ago)

    result = ingest("succeeded")

    assert_equal started.id, result[:event].id
    assert result[:changed]
    assert_predicate result[:event].succeeded_at, :present?
    assert_equal 1, DeployEvent.count
  end

  test "an inferred row does not swallow a later post-deploy report as a duplicate" do
    DeployEvent.create!(managed_app: @app, version: "aaaaaaa", source: "inferred",
                        succeeded_at: 10.seconds.ago, observed_at: 10.seconds.ago)

    result = ingest("succeeded", version: "aaaaaaa")

    assert_equal 2, DeployEvent.count
    assert result[:changed]
    assert_equal "ci", result[:event].performer
    assert_equal "hook", result[:event].source
  end

  test "recorded_at is stored as given, but started_at uses the server time" do
    lie = 1.hour.from_now
    event = ingest("started", recorded_at: lie)[:event]

    assert_in_delta lie, event.recorded_at, 1.second
    assert_operator event.started_at, :<, 1.minute.from_now
  end
end
