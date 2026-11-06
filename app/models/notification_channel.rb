# Where alert notifications go (spec 8). Admin-managed like Git connections: the target (a webhook
# URL is itself a credential — whoever holds it can post) and the signing secret are encrypted,
# never rendered back in full, and only replaced as a whole.
class NotificationChannel < ApplicationRecord
  KINDS = %w[webhook feishu slack email].freeze
  URL_KINDS = %w[webhook feishu slack].freeze

  # Deliberately loose: the mail server is the real judge. This only catches typos like a missing @
  # or a stray space, so a test mail isn't the first place they show up.
  EMAIL_FORMAT = /\A[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+\z/
  MAX_RECIPIENTS = 20

  encrypts :target
  encrypts :secret

  has_many :alert_rule_channels, dependent: :destroy
  has_many :alert_rules, through: :alert_rule_channels

  scope :enabled, -> { where(enabled: true) }

  before_validation :normalize

  validates :name, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }
  validates :target, presence: true
  validate :target_must_suit_kind

  def url_kind? = URL_KINDS.include?(kind)
  def email? = kind == "email"

  def recipients = email? ? target.to_s.split(",").map(&:strip).reject(&:blank?) : []

  # Enough to tell two channels apart without handing out the webhook: scheme and host only for a
  # URL (the path is where Slack / Feishu put the token), the mailbox domains for email.
  def target_hint
    if email?
      recipients.map { |address| "…@#{address.split('@').last}" }.uniq.join(", ")
    else
      uri = URI.parse(target.to_s)
      "#{uri.scheme}://#{uri.host}/…"
    end
  rescue URI::InvalidURIError
    "…"
  end

  def notifier = Notifiers.for(self)

  # Synchronous; returns a Notifiers::Result. Used by the delivery job and the "send test" button.
  def deliver(message) = notifier.deliver(message)

  def record_delivery!(result)
    if result.ok?
      update_columns(last_delivered_at: Time.current, last_error: nil, last_error_at: nil)
    else
      update_columns(last_error: result.error.to_s.truncate(1000), last_error_at: Time.current)
    end
  end

  def serializable_hash(options = nil)
    super(options).except("target", "secret")
  end

  private
    def normalize
      self.target = target.to_s.strip
      self.target = recipients.join(", ") if email?
      self.secret = secret.to_s.strip.presence
    end

    def target_must_suit_kind
      return if target.blank?

      if email?
        addresses = recipients
        errors.add(:target, :invalid_email) if addresses.empty? || addresses.any? { |a| !EMAIL_FORMAT.match?(a) }
        errors.add(:target, :too_many_recipients, count: MAX_RECIPIENTS) if addresses.size > MAX_RECIPIENTS
      elsif url_kind?
        # https only: the URL carries the token, and the payload carries app names and log excerpts.
        uri = URI.parse(target)
        errors.add(:target, :not_https) unless uri.is_a?(URI::HTTPS) && uri.host.present?
      end
    rescue URI::InvalidURIError
      errors.add(:target, :not_https)
    end
end
