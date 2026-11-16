require "test_helper"

# Each kind of work has its own worker (config/queue.yml), so long actions can't take the threads
# that status collection and alerting need. A job left on the wrong queue silently undoes that.
class JobQueuesTest < ActiveSupport::TestCase
  EXPECTED = {
    RunActionJob => "actions",
    EvaluateAlertRulesJob => "alerts",
    DeliverAlertNotificationJob => "alerts",
    PollAllManagedAppsJob => "collect",
    PollManagedAppJob => "collect",
    CollectAllMetricsJob => "collect",
    CollectMetricsJob => "collect",
    EvaluateLogRuleJob => "collect",
    PruneObservationsJob => "default",
    RunBackupJob => "backups",
    ScheduleBackupsJob => "default",
    CheckCertificatesJob => "collect",
    CheckPanelUpdatesJob => "default",
    WeeklySummaryJob => "alerts",
    StatusPageSampleJob => "default"
  }.freeze

  test "every job runs on its own kind of queue" do
    EXPECTED.each { |job, queue| assert_equal queue, job.queue_name, job.name }
  end

  test "every queue a job uses has a worker" do
    config = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/queue.yml"))
    served = config.fetch("production").fetch("workers").flat_map { |worker| Array(worker["queues"]) }

    EXPECTED.each_value { |queue| assert_includes served, queue }
  end
end
