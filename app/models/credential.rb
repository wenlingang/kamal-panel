require "digest"
require "base64"

# 加密存储的 SSH 私钥。
# value 是不可信字节，解析耗时由攻击者可控的字段决定，所以交给 SshKeyValidator 的子进程 + 硬超时。
class Credential < ApplicationRecord
  include WriteOnlySecret

  KINDS = %w[ssh_key].freeze

  MAX_VALUE_BYTES = 16 * 1024

  # "没有私钥"，而操作的人看不到任何提示。要删就先把引用它的应用换掉。
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
      return if value.bytesize > MAX_VALUE_BYTES # 已经在 value_within_size_limit 里报过错

      result = validation_result
      return if result&.ok?

      if result&.encrypted?
        errors.add(:value, :encrypted)
      else
        errors.add(:value, :not_a_private_key)
      end
    end
end
