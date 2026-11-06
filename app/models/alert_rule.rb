# What to watch for (spec 8). One rule covers one app or, with no app, every active app; each
# (rule, app) pair has at most one open AlertEvent at a time (event-type conditions: one per
# source record).
class AlertRule < ApplicationRecord
  # Conditions judged from the latest collection round; they hold or not, so they go pending →
  # firing after for_minutes and resolve when they stop holding.
  # Resource metrics (CollectMetricsJob): usage at or over a percentage threshold. State
  # conditions too; no recent sample means no verdict.
  METRIC_CONDITIONS = %w[cpu_high memory_high host_memory_high host_disk_high].freeze
  STATE_CONDITIONS = (%w[unhealthy unreachable drift] + METRIC_CONDITIONS).freeze
  # Conditions that are a single past event (one failed deploy / action); each fires once,
  # immediately, and for_minutes doesn't apply.
  EVENT_CONDITIONS = %w[deploy_failed action_failed].freeze
  # Counted over a window of log lines, then treated like a state condition.
  LOG_CONDITIONS = %w[log_keyword].freeze
  CONDITIONS = (STATE_CONDITIONS + EVENT_CONDITIONS + LOG_CONDITIONS).freeze

  FOR_MINUTES = 0..120
  WINDOW_MINUTES = 1..60
  DEFAULT_WINDOW_MINUTES = 5
  MAX_THRESHOLD = 1000
  METRIC_THRESHOLDS = 1..100
  DEFAULT_METRIC_THRESHOLD = 90

  belongs_to :managed_app, optional: true
  has_many :alert_rule_channels, dependent: :destroy
  has_many :notification_channels, through: :alert_rule_channels
  has_many :alert_events, dependent: :destroy

  # The log-rule settings live in the params JSON; these make them ordinary form fields.
  store_accessor :params, :keyword, :window_minutes, :threshold, :log_source

  scope :enabled, -> { where(enabled: true) }

  before_validation :normalize_params

  validates :name, presence: true
  validates :condition, inclusion: { in: CONDITIONS }
  validates :for_minutes, numericality: { only_integer: true, in: FOR_MINUTES }
  with_options if: :log_keyword? do
    validates :keyword, presence: true, length: { maximum: LogQuery::MAX_KEYWORD_LENGTH }
    validates :window_minutes, numericality: { only_integer: true, in: WINDOW_MINUTES }
    validates :threshold, numericality: { only_integer: true, in: 1..MAX_THRESHOLD }
  end
  validates :metric_threshold, numericality: { only_integer: true, in: METRIC_THRESHOLDS }, if: :metric_condition?
  validate :keyword_must_be_printable, if: :log_keyword?
  validate :log_source_requires_one_app, if: :log_keyword?

  # A rule that now means something else (other condition, other app) or that was switched off
  # leaves no event open on its old meaning; closing them is bookkeeping, nobody is notified.
  after_update :close_open_events, if: -> { saved_change_to_condition? || saved_change_to_managed_app_id? || (saved_change_to_enabled? && !enabled?) }

  def state_condition? = STATE_CONDITIONS.include?(condition)
  def event_condition? = EVENT_CONDITIONS.include?(condition)
  def log_keyword? = condition == "log_keyword"
  def metric_condition? = METRIC_CONDITIONS.include?(condition)

  # The metric rules' percentage. Stored in params["threshold"] like the log rules' count, but a
  # form field of its own: both fields are on the form at once (the hidden one still submits), and
  # one name would let whichever comes last win.
  def metric_threshold
    defined?(@metric_threshold) ? @metric_threshold : (threshold if metric_condition?)
  end

  def metric_threshold=(value)
    @metric_threshold = value
  end

  def reload(*)
    remove_instance_variable(:@metric_threshold) if defined?(@metric_threshold)
    super
  end

  def all_apps? = managed_app_id.nil?

  # The apps this rule watches right now.
  def apps
    scope = ManagedApp.active
    all_apps? ? scope : scope.where(id: managed_app_id)
  end

  def window = window_minutes.to_i.minutes

  # Log rules scan once per window (at most once a minute): scanning more often would count the
  # same lines again; less often would leave gaps.
  def log_scan_due?(now = Time.current)
    last_evaluated_at.nil? || last_evaluated_at <= now - window + 5.seconds
  end

  def condition_label = I18n.t("alert_rules.conditions.#{condition}")

  def record_error!(message)
    update_columns(last_error: message.to_s.truncate(1000), last_error_at: Time.current)
  end

  def clear_error!
    update_columns(last_error: nil, last_error_at: nil) if last_error.present?
  end

  private
    def normalize_params
      self.params = {} unless params.is_a?(Hash)
      if log_keyword?
        self.keyword = keyword.to_s.strip
        self.window_minutes = integer_or_raw(window_minutes, DEFAULT_WINDOW_MINUTES)
        self.threshold = integer_or_raw(threshold, 1)
        self.log_source = log_source.to_s.strip.presence || "app"
      elsif metric_condition?
        value = integer_or_raw(metric_threshold, DEFAULT_METRIC_THRESHOLD)
        self.params = { "threshold" => value }
        @metric_threshold = value
      else
        # Leftover log settings on a rule that is no longer a log rule would only confuse a reader.
        self.params = {}
      end
    end

    # Form input arrives as strings; store numbers as numbers, but keep garbage as-is so the
    # numericality validation can name it instead of it silently becoming 0.
    def integer_or_raw(value, default)
      value = value.to_s.strip
      return default if value.empty?

      Integer(value, 10, exception: false) || value
    end

    def keyword_must_be_printable
      errors.add(:keyword, :invalid) if keyword.to_s.match?(/[\x00-\x1f\x7f]/)
    end

    # A source other than "app" names a role / accessory of one app's config; across apps it
    # means nothing.
    def log_source_requires_one_app
      return if log_source.blank? || log_source == "app"

      if all_apps?
        errors.add(:log_source, :requires_app)
      elsif managed_app && managed_app.last_poll_error.blank?
        keys = LogQuery.sources_for(managed_app.parsed_config).map(&:key)
        errors.add(:log_source, :inclusion) unless keys.include?(log_source)
      end
    rescue Kamal::ConfigParser::ParseError
      nil
    end

    def close_open_events
      alert_events.unresolved.find_each(&:close_silently!)
    end
end
