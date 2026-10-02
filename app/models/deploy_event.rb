# One row is one deploy attempt, not one report (spec 03 §3).
class DeployEvent < ApplicationRecord
  belongs_to :managed_app

  # Only has to cover the gap between "the container is up" and "the next poll sees it".
  UNOBSERVED_AFTER = 90.seconds
  # Has to cover a whole normal deploy (build + health check).
  # Folding both into one constant would make one of them fire false alarms.
  UNFINISHED_AFTER = 15.minutes

  # can't supply performer / command, and never sees a failed deploy.
  SOURCES = %w[hook inferred].freeze

  validates :version, presence: true
  validates :source, inclusion: { in: SOURCES }

  scope :recent_first, -> { order(created_at: :desc) }

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
    return I18n.t("deploy_events.unverified") unless succeeded_at

    delay = observation_delay
    return I18n.t("deploy_events.observed_before_report") if delay.nil? || delay <= 0

    I18n.t("deploy_events.delayed_seconds", seconds: delay.round)
  end

  # Two kinds of fact share one table; a reader must see at a glance which rows the machine
  # reported and which the panel inferred.
  def source_text
    I18n.t(source == "inferred" ? "deploy_events.inferred" : "deploy_events.hook_reported")
  end
end
