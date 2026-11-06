require "test_helper"

# Panel deploys and rollbacks leave a DeployEvent (source "panel") next to hook-reported and
# inferred ones, and unlike those they can record a failure. The CLI and the lock are stubbed:
# what's under test is the bookkeeping around them, not Kamal.
class RunActionJobDeployEventTest < ActiveSupport::TestCase
  setup do
    @managed_app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                                      destination: "production")
    @user = users(:two)
  end

  def start(action_name, version: "abc1234")
    AuditLog.start!(user: @user, managed_app: @managed_app, action_name: action_name,
                    target_version: version, hosts: [ "127.0.0.1" ])
  end

  def run_with(exit_status: 0, locked: false, raise_error: nil)
    invocation = Object.new
    invocation.define_singleton_method(:run) do |_args, &block|
      raise raise_error if raise_error

      block.call("INFO deploying")
      { status: exit_status, output: "INFO deploying" }
    end
    lock = Object.new
    lock.define_singleton_method(:status) { { locked: locked, details: ("Locked by: ci" if locked) } }

    with_stubbed_new(KamalCli::Invocation, invocation) do
      with_stubbed_new(KamalLock, lock) { yield }
    end
  end

  def with_stubbed_new(klass, instance)
    original = klass.method(:new)
    klass.define_singleton_method(:new) { |*| instance }
    yield
  ensure
    klass.define_singleton_method(:new, original)
  end

  test "a successful deploy opens a panel event at start and closes it as succeeded" do
    log = start("deploy")

    run_with(exit_status: 0) { RunActionJob.new.perform(log.id) }

    event = @managed_app.deploy_events.sole
    assert_equal "panel", event.source
    assert_equal "abc1234", event.version
    assert_equal "deploy", event.command
    assert_equal @user.display_name, event.performer
    assert_equal log, event.audit_log
    assert_not_nil event.started_at
    assert_not_nil event.succeeded_at
    assert_nil event.failed_at
    assert_equal :success, event.result
  end

  test "a failed deploy is kept in the history as failed" do
    log = start("deploy")

    run_with(exit_status: 1) { RunActionJob.new.perform(log.id) }

    event = @managed_app.deploy_events.sole
    assert_predicate event, :failed?
    assert_nil event.succeeded_at
    assert_equal :failure, event.result
    assert_equal "failure", log.reload.result
  end

  test "a crash mid-run also closes the event as failed" do
    log = start("deploy")

    run_with(raise_error: RuntimeError.new("boom")) { RunActionJob.new.perform(log.id) }

    assert_predicate @managed_app.deploy_events.sole, :failed?
  end

  test "rollbacks are recorded the same way" do
    log = start("rollback", version: "0ld1234")

    run_with { RunActionJob.new.perform(log.id) }

    event = @managed_app.deploy_events.sole
    assert_equal "rollback", event.command
    assert_equal "0ld1234", event.version
  end

  test "a deploy the lock refused never ran, so it leaves no event (its audit row says why)" do
    log = start("deploy")

    run_with(locked: true) { RunActionJob.new.perform(log.id) }

    assert_empty @managed_app.deploy_events
    assert_match "部署进行中", log.reload.output_digest
  end

  test "other actions don't touch deploy history" do
    log = start("restart")

    run_with { RunActionJob.new.perform(log.id) }

    assert_empty @managed_app.deploy_events
  end

  test "a failed panel deploy raises no 'unfinished' alert" do
    log = start("deploy")
    run_with(exit_status: 1) { RunActionJob.new.perform(log.id) }

    travel DeployEvent::UNFINISHED_AFTER + 1.minute do
      assert_not DeployAlerts.new(@managed_app).any?
    end
  end
end
