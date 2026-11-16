# While a silence is on, alerts for its app (or for every app) are still evaluated and shown, but
# nobody is notified: planned maintenance, a migration everyone knows is noisy, or the app sitting
# in Kamal's maintenance mode. An event still firing when the silence ends is notified by the
# usual reminder (AlertEvent::RENOTIFY_AFTER).
class AlertSilence < ApplicationRecord
  SOURCES = %w[manual maintenance_mode].freeze
  # The lengths offered on the form, in minutes; "until lifted" is an empty ends_at.
  DURATIONS = [ 30, 60, 120, 240, 480, 1440, 4320 ].freeze

  belongs_to :managed_app, optional: true
  belongs_to :user, optional: true

  validates :source, inclusion: { in: SOURCES }
  validates :starts_at, presence: true
  validates :reason, length: { maximum: 200 }
  validate :ends_after_start

  scope :active, ->(now = Time.current) { where(starts_at: ..now).where("ends_at IS NULL OR ends_at > ?", now) }
  scope :upcoming, ->(now = Time.current) { where("starts_at > ?", now) }
  scope :current_or_upcoming, ->(now = Time.current) { where("ends_at IS NULL OR ends_at > ?", now) }

  # Whether notifications for this app are held right now (an app's own silence or a global one).
  def self.silenced?(managed_app_id, now = Time.current)
    active(now).where(managed_app_id: [ nil, managed_app_id ]).exists?
  end

  # Kamal's maintenance mode silences the app until it goes live again; the panel knows both ends
  # because it ran both actions.
  def self.start_maintenance!(managed_app, user)
    return if active.exists?(managed_app:, source: "maintenance_mode")

    create!(managed_app:, user:, source: "maintenance_mode", starts_at: Time.current,
            reason: I18n.t("alert_silences.maintenance_reason", locale: I18n.default_locale))
  end

  def self.end_maintenance!(managed_app, now = Time.current)
    active(now).where(managed_app:, source: "maintenance_mode").update_all(ends_at: now, updated_at: now)
  end

  def global? = managed_app_id.nil?
  def maintenance_mode? = source == "maintenance_mode"
  def active?(now = Time.current) = starts_at <= now && (ends_at.nil? || ends_at > now)

  def end!(now = Time.current)
    update!(ends_at: [ now, starts_at ].max)
  end

  private
    def ends_after_start
      errors.add(:ends_at, :after_start) if ends_at && starts_at && ends_at <= starts_at
    end
end
