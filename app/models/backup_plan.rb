# Backing up one accessory of one app: which database engine it runs, how often to dump it and how
# many dumps to keep. Due plans are picked up by ScheduleBackupsJob; each dump is a BackupRun.
class BackupPlan < ApplicationRecord
  ENGINES = %w[postgres mysql].freeze
  EVERY_HOURS = [ 1, 2, 3, 4, 6, 8, 12, 24, 48, 168 ].freeze
  KEEP = 1..365

  belongs_to :managed_app
  belongs_to :backup_destination
  has_many :backup_runs, dependent: :destroy

  scope :enabled, -> { where(enabled: true) }
  scope :due, ->(now = Time.current) { enabled.where(next_run_at: ..now) }

  before_validation :normalize
  before_save :schedule_first_run

  validates :accessory, presence: true, uniqueness: { scope: :managed_app_id }
  validates :engine, inclusion: { in: ENGINES }
  validates :every_hours, inclusion: { in: EVERY_HOURS }
  validates :keep, numericality: { only_integer: true, in: KEEP }
  # Goes into a shell command on the host (shell-escaped there too); a database name never needs
  # more than this.
  validates :database, format: { with: /\A[\w.\-]+\z/ }, allow_blank: true
  validate :accessory_must_be_declared

  # The engine an accessory's image most likely runs: "postgres:16" → postgres, "mysql:8" or
  # "mariadb:11" → mysql. nil when it's something else (Redis, a search engine...).
  def self.engine_for_image(image)
    case image.to_s.split("/").last.to_s
    when /\A(postgres|postgis|timescale)/ then "postgres"
    when /\A(mysql|mariadb|percona)/ then "mysql"
    end
  end

  # The accessories of an app that hold a database this panel knows how to dump.
  def self.candidates(managed_app)
    managed_app.parsed_config.accessories.filter_map do |accessory|
      engine = engine_for_image(accessory[:image])
      { name: accessory[:name], engine:, image: accessory[:image] } if engine
    end
  rescue Kamal::ConfigParser::ParseError
    []
  end

  def accessory_config = managed_app.parsed_config.accessory(accessory)

  def last_run = backup_runs.order(started_at: :desc).first

  # Claims this plan's due run: moves next_run_at forward with a compare-and-set, so two scheduler
  # ticks that overlap start one backup, not two. True for the caller that moved it.
  def claim_due!(now = Time.current)
    claimed = self.class.where(id:, next_run_at:).update_all(next_run_at: now + every_hours.hours, updated_at: now)
    reload if claimed == 1
    claimed == 1
  end

  private
    def normalize
      self.database = database.to_s.strip.presence
    end

    # A new plan, or one switched back on, runs at its next tick rather than waiting a whole period.
    def schedule_first_run
      self.next_run_at = Time.current if next_run_at.nil? || (will_save_change_to_enabled? && enabled?)
    end

    def accessory_must_be_declared
      return if managed_app.nil? || accessory.blank?

      errors.add(:accessory, :inclusion) unless managed_app.parsed_config.accessory_names.include?(accessory)
    rescue Kamal::ConfigParser::ParseError
      errors.add(:accessory, :inclusion)
    end
end
