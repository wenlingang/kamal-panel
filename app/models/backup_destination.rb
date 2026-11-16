# Where accessory backups go: a bucket on any S3-compatible object storage. Admin-managed like
# notification channels: the secret key is encrypted, write-only, and replaced as a whole.
class BackupDestination < ApplicationRecord
  encrypts :secret_access_key

  has_many :backup_plans, dependent: :restrict_with_error

  before_validation :normalize

  validates :name, presence: true, uniqueness: true
  validates :endpoint, :bucket, :access_key_id, :secret_access_key, presence: true
  validates :bucket, format: { with: /\A[a-z0-9][a-z0-9.\-]{1,61}[a-z0-9]\z/ }, allow_blank: true
  validate :endpoint_must_be_http

  # "prefix/rest", or just "rest" without a prefix.
  def key_for(rest) = [ prefix.presence, rest ].compact.join("/")

  def storage = ObjectStorage.new(self)

  # Where it points, for lists: no keys, just the place.
  def location = "#{endpoint.to_s.sub(%r{\Ahttps?://}, '')} · #{[ bucket, prefix.presence ].compact.join('/')}"

  # Runs ObjectStorage#check! and remembers the outcome; returns the error text, or nil when it works.
  def check!
    storage.check!
    update_columns(last_checked_at: Time.current, last_check_error: nil)
    nil
  rescue ObjectStorage::Error => e
    update_columns(last_checked_at: Time.current, last_check_error: e.message.truncate(1000))
    e.message
  end

  def serializable_hash(options = nil)
    super(options).except("secret_access_key")
  end

  private
    def normalize
      self.endpoint = endpoint.to_s.strip.chomp("/")
      self.prefix = prefix.to_s.strip.delete_prefix("/").delete_suffix("/").presence
      self.region = region.to_s.strip.presence || "us-east-1"
      self.bucket = bucket.to_s.strip
      self.access_key_id = access_key_id.to_s.strip
    end

    def endpoint_must_be_http
      uri = URI.parse(endpoint.to_s)
      errors.add(:endpoint, :invalid) unless uri.is_a?(URI::HTTP) && uri.host.present?
    rescue URI::InvalidURIError
      errors.add(:endpoint, :invalid)
    end
end
