# One row is one deploy attempt, not one report (spec 03 §3).
class DeployEvent < ApplicationRecord
  belongs_to :managed_app
  # Panel deploys and rollbacks only: the audit row whose recorded output is this attempt's.
  belongs_to :audit_log, optional: true

  # Only has to cover the gap between "the container is up" and "the next poll sees it".
  UNOBSERVED_AFTER = 90.seconds
  # Has to cover a whole normal deploy (build + health check).
  # Folding both into one constant would make one of them fire false alarms.
  UNFINISHED_AFTER = 15.minutes

  # can't supply performer / command, and never sees a failed deploy.
  # panel: started from the panel itself (RunActionJob), the one source that sees failures too.
  SOURCES = %w[hook inferred panel].freeze

  validates :version, presence: true
  validates :source, inclusion: { in: SOURCES }

  scope :recent_first, -> { order(created_at: :desc) }
  # A failed attempt is history, not a claim that anything is (or should be) running.
  scope :not_failed, -> { where(failed_at: nil) }

  def failed? = failed_at.present?
  def panel? = source == "panel"

  # :success / :failure / :running. Only a panel row can end in :failure; a hook row that never
  # got its success report stays :running here and becomes DeployAlerts' "unfinished".
  def result
    if failed? then :failure
    elsif succeeded_at then :success
    else :running
    end
  end

  def finished_at = failed_at || succeeded_at

  # The panel itself confirmed this version is running — not the same as "the report says it
  # succeeded".
  def observed? = observed_at.present?

  def observation_delay
    return nil unless observed_at && succeeded_at

    observed_at - succeeded_at
  end

  def observation_delay_text
    # convergence moment, so a computed delay of 0 seconds means nothing.
    return I18n.t("deploy_events.observed_by_panel") if source == "inferred"

    return nil unless observed?
    # A failed deploy has no success moment to measure against; seeing the version is all there is
    # to say (it may have reached some hosts before failing).
    return I18n.t("deploy_events.observed_by_panel") if failed?
    return I18n.t("deploy_events.unverified") unless succeeded_at

    delay = observation_delay
    return I18n.t("deploy_events.observed_before_report") if delay.nil? || delay <= 0

    I18n.t("deploy_events.delayed_seconds", seconds: delay.round)
  end

  # Two kinds of fact share one table; a reader must see at a glance which rows the machine
  # reported and which the panel inferred.
  def source_text
    I18n.t({ "inferred" => "deploy_events.inferred", "panel" => "deploy_events.panel" }
             .fetch(source, "deploy_events.hook_reported"))
  end
end
