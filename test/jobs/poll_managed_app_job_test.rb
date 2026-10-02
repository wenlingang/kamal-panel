require "test_helper"

class PollManagedAppJobTest < ExecutionLayerTest
  include ActionCable::TestHelper

  setup do
    FakeHost.start_proxy("node-1")
  end

  def build_app
    yaml = <<~YAML
      service: blog
      image: example/blog
      servers:
        web:
          - 127.0.0.1
      registry:
        server: registry.example.com
        username: someone
        password:
          - KAMAL_REGISTRY_PASSWORD
      builder:
        arch: amd64
      ssh:
        user: deploy
        port: #{FakeHost::NODES.fetch("node-1")}
    YAML

    app_name = "blog-#{SecureRandom.hex(4)}"
    ManagedApp.create!(
      name: app_name, config_yaml: yaml, destination: "production",
      ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key,
                                      name: "#{app_name} 的 SSH 私钥")
    )
  end

  test "a poll writes both container observations and the routing snapshot" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")
    FakeHost.proxy_deploy(node: "node-1", service: "blog-web-production",
                          target: "blog-web-production-aaaaaaa:80")

    app = build_app
    PollManagedAppJob.perform_now(app)

    assert_equal "aaaaaaa", Observation.latest_for(app).first.version

    target = ProxyTarget.where(managed_app: app).sole
    assert_equal "blog-web-production", target.service_name
    assert_match(/blog-web-production-aaaaaaa/, target.target)
  end

  test "does not crash when the collector raises and leaves an unreachable trace" do
    app = build_app
    app.update_column(:config_yaml, app.config_yaml.sub("127.0.0.1", "192.0.2.1"))
    app.reload

    assert_nothing_raised { PollManagedAppJob.perform_now(app) }
    refute Observation.latest_for(app).first.reachable
  end

  # Broadcasting is the other half of this job: whether the overview page updates without
  # a manual refresh depends entirely on whether a message really goes to the "overview"
  # stream, and whether the target is the #overview-grid the page subscribes to and waits
  # to have replaced. Verifying only "the collection wrote to the DB" is not enough --
  # if the stream name or target id is mistyped, the page quietly stops updating while
  # every test stays green. This pins down the server half: the broadcast really happens,
  # goes to the right stream, and replaces the right DOM node.
  test "records the reason on the ManagedApp when deploy.yml cannot be parsed, not just a log line" do
    app = build_app
    # Break config_yaml so it no longer parses -- while making sure the destination validation
    # doesn't block first (config_yaml_must_parse is skipped when destination already has an error).
    app.update_column(:config_yaml, "not: valid: kamal: yaml: [")
    app.reload

    assert_nil app.last_poll_error

    PollManagedAppJob.perform_now(app)
    app.reload

    assert_predicate app.last_poll_error, :present?,
      "An unparseable config must leave a trace on ManagedApp so the UI can show it (see final review I4)"
    assert_predicate app.last_poll_error_at, :present?
  end

  test "keeps first_poll_error_at at the first failure time across consecutive failures" do
    app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                             destination: "production")
    app.update_column(:config_yaml, "不是配置")
    # update_column bypasses the step in config_yaml= that invalidates @parsed_config (see
    # ManagedApp#config_yaml=); the create! validation phase has already cached the old
    # valid parse result on this in-memory object. Only after reload does it match
    # production: there PollManagedAppJob goes through perform_later, and each polling
    # round deserializes a freshly loaded ManagedApp that carries no cache from last time.
    app.reload

    travel_to Time.utc(2026, 9, 6, 10, 0, 0) do
      PollManagedAppJob.perform_now(app)
    end
    first = app.reload.first_poll_error_at

    travel_to Time.utc(2026, 9, 6, 12, 0, 0) do
      PollManagedAppJob.perform_now(app)
    end

    assert_equal first, app.reload.first_poll_error_at
    assert_operator app.last_poll_error_at, :>, first
  end

  test "clears the previously recorded parse error on the next poll once the config is parseable again" do
    app = build_app
    app.update_columns(last_poll_error: "之前记录的错误", last_poll_error_at: 1.hour.ago)

    PollManagedAppJob.perform_now(app)
    app.reload

    assert_nil app.last_poll_error, "Once the config parses again, the old error trace should not linger"
    assert_nil app.last_poll_error_at
  end

  # What gets broadcast is a refresh rather than a rendered grid: the overview page
  # supports filtering by name/status, and the server doesn't know which browser is
  # filtering by what; rendering a full grid and swapping it in would quietly replace a
  # filtering user's results with everything. A refresh makes each browser come back with
  # its own current URL (i.e. its own filters) and re-request, and the page merges with morph.
  test "broadcasts one refresh to the overview channel after polling, not a rendered grid" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")
    FakeHost.proxy_deploy(node: "node-1", service: "blog-web-production",
                          target: "blog-web-production-aaaaaaa:80")

    app = build_app

    assert_broadcasts("overview", 1) { PollManagedAppJob.perform_now(app) }

    message = ActiveSupport::JSON.decode(broadcasts("overview").last)
    assert_includes message, 'action="refresh"'
    refute_includes message, 'target="overview-grid"',
      "The server must not render the grid for anyone; it does not know what they are filtering"
  end

  test "also broadcasts once to the app's own stream after polling so the detail page stays live" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")
    app = build_app
    stream = "managed_app_#{app.id}"

    assert_broadcasts(stream, 1) { PollManagedAppJob.perform_now(app) }

    message = ActiveSupport::JSON.decode(broadcasts(stream).last)
    assert_includes message, 'action="replace"'
    assert_includes message, 'target="host-status"',
      "The replace target must be #host-status; if this id changes, the detail page stays stuck on stale data"
    assert_includes message, "aaaaaaa",
      "The broadcast should carry the re-rendered host status, showing the version just collected"
  end

  # Broadcast failure -- only the "delivery" step (Solid Cable hiccups, serialization
  # problems...) -- shouldn't take down a collection result that was already persisted.
  # It's the same reasoning as the two collectors running independently of each other
  # (Task 9): a side-channel failure unrelated to "did the collection succeed" shouldn't
  # make Solid Queue mark this run as a failed job and retry a collection that actually
  # already succeeded.
  #
  # What we deliberately stub is Turbo::StreamsChannel.broadcast_stream_to -- the step that
  # really hands the message to ActionCable -- rather than a higher-level method, because
  # the test below, "an exception in the render phase must fail the job", is there to prove
  # exactly this: rendering (ManagedAppStatus, partial) and delivery are now two separate
  # stages, and only delivery is covered by the safety net. If the method stubbed here
  # covered both stages, the two tests couldn't tell which half the safety net protects.
  test "a failed broadcast delivery does not affect persisting results and does not fail the job" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")

    app = build_app

    with_stubbed_method(Turbo::StreamsChannel, :broadcast_stream_to, ->(*) { raise "solid cable 抖了一下" }) do
      assert_nothing_raised { PollManagedAppJob.perform_now(app) }
    end

    assert_equal "aaaaaaa", Observation.latest_for(app).first.version
  end

  # The flip side: an exception in the render phase (ManagedAppStatus computed wrongly, a
  # bug in the partial...) must be raised as usual and fail the job so it gets retried --
  # it must not be swallowed in passing by the "broadcast failure is a self-healing
  # degradation" safety net, otherwise a real code bug would degrade into "the overview
  # page quietly stops updating, with only a log line" while all tests stay green, which
  # is exactly the regression this review wants to block.
  test "a rendering error fails the job and is not swallowed by the broadcast rescue" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")

    app = build_app

    error = with_stubbed_method(ApplicationController, :render, ->(*) { raise "partial 渲染炸了" }) do
      assert_raises(RuntimeError) { PollManagedAppJob.perform_now(app) }
    end

    assert_equal "partial 渲染炸了", error.message
    # A render blowing up shouldn't take down the collection results -- they were already saved
    # before the broadcast.
    assert_equal "aaaaaaa", Observation.latest_for(app).first.version
  end

  test "the first poll sets a convergence baseline and the second poll with a new version infers a deploy" do
    app = build_app
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")

    PollManagedAppJob.perform_now(app)

    assert_equal "aaaaaaa", app.reload.last_converged_version
    assert_equal 0, app.deploy_events.count, "The first convergence only sets the baseline"

    FakeHost.reset!("node-1")
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "bbbbbbb")

    PollManagedAppJob.perform_now(app)

    event = app.deploy_events.sole
    assert_equal "bbbbbbb", event.version
    assert_equal "inferred", event.source
    assert_empty DeployAlerts.new(app).list, "The inferred row is already backed by observation and must not trigger an alert"
  end

  test "a poll backfills observed_at" do
    app = build_app
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")
    event = DeployEvent.create!(managed_app: app, version: "aaaaaaa", source: "hook",
                                succeeded_at: 1.minute.ago)

    PollManagedAppJob.perform_now(app)

    assert_predicate event.reload.observed_at, :present?
  end

  private
    def with_stubbed_method(receiver, method_name, replacement)
      original = receiver.method(method_name)
      receiver.define_singleton_method(method_name, &replacement)
      yield
    ensure
      receiver.define_singleton_method(method_name, original)
    end

  # A collection round may already be queued when the app is disabled. It shouldn't revive
  # the app and collect it again -- that would pile up one more failed observation after
  # disabling (the credentials have already been released).
  test "an already-enqueued poll gives up when it meets a deactivated app" do
    app = build_app
    app.deactivate!

    assert_no_difference -> { Observation.where(managed_app: app).count } do
      PollManagedAppJob.perform_now(app)
    end
  end
end
