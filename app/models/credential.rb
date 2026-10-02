require "digest"
require "base64"

# An encrypted SSH private key. value is untrusted bytes, and parse time is determined by
# attacker-controllable fields, so it is handed to SshKeyValidator's subprocess + hard timeout.
class Credential < ApplicationRecord
  include WriteOnlySecret

  KINDS = %w[ssh_key].freeze

  MAX_VALUE_BYTES = 16 * 1024

  # "no private key", with no hint shown to the person operating. To delete it, first switch the
  # apps that reference it to another.
  has_many :managed_apps, foreign_key: :ssh_credential_id, dependent: :restrict_with_error,
           inverse_of: :ssh_credential

  validates :kind, inclusion: { in: KINDS }
  validate :value_within_size_limit
  validate :value_must_be_a_private_key

  before_save :store_fingerprint, if: :will_save_change_to_value?

  def fingerprint
    super || backfill_fingerprint
  end

  private
    def store_fingerprint
      self.fingerprint = validation_result&.fingerprint
    end

    def backfill_fingerprint
      computed = validation_result&.fingerprint
      update_column(:fingerprint, computed) if computed.present? && persisted?
      computed.presence || I18n.t("credentials.fingerprint_unreadable")
    end

    def validation_result
      return @validation_result if defined?(@validation_result) && @validation_result_source == value
      return nil if value.blank? || value.bytesize > MAX_VALUE_BYTES

      @validation_result_source = value
      @validation_result = SshKeyValidator.call(value)
    end

    def value_within_size_limit
      return if value.blank?

      errors.add(:value, :too_long) if value.bytesize > MAX_VALUE_BYTES
    end

    def value_must_be_a_private_key
      return if value.blank?
      return if value.bytesize > MAX_VALUE_BYTES # already reported in value_within_size_limit

      result = validation_result
      return if result&.ok?

      if result&.encrypted?
        errors.add(:value, :encrypted)
      else
        errors.add(:value, :not_a_private_key)
      end
    end
end
