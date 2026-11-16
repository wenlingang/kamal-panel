# One dump of one BackupPlan: running → succeeded (with the object it wrote) or failed (with why).
# A succeeded run whose object was removed by retention keeps its row, marked pruned.
class BackupRun < ApplicationRecord
  STATES = %w[running succeeded failed].freeze
  # A run still "running" after this was cut off (the panel restarted mid-dump); it counts as failed.
  STALE_AFTER = 3.hours

  belongs_to :backup_plan
  belongs_to :managed_app
  belongs_to :user, optional: true

  serialize :diagnosis, coder: JSON

  validates :state, inclusion: { in: STATES }

  scope :succeeded, -> { where(state: "succeeded") }
  scope :failed, -> { where(state: "failed") }
  scope :recent_first, -> { order(started_at: :desc, id: :desc) }
  scope :downloadable, -> { succeeded.where(pruned_at: nil).where.not(object_key: nil) }

  def running? = state == "running"
  def succeeded? = state == "succeeded"
  def failed? = state == "failed"
  def downloadable? = succeeded? && pruned_at.nil? && object_key.present?
  def scheduled? = user_id.nil?

  def duration = finished_at && (finished_at - started_at)

  def explained_failure = diagnosis && FailureDiagnosis.explain(diagnosis)
end
