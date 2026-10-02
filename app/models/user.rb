class User < ApplicationRecord
  ROLES = %w[admin developer ops].freeze

  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :app_memberships, dependent: :destroy
  has_many :managed_apps, through: :app_memberships

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  # but it makes nickname.nil? and nickname.blank? give different answers. Keep only one kind of
  # empty value.
  normalizes :nickname, with: ->(n) { n.strip.presence }

  validates :role, inclusion: { in: ROLES }
  # while an empty email could store an account that can never log in. Both must be stopped at the
  # model layer.
  validates :email_address, presence: true, uniqueness: true
  validates :password, length: { minimum: 8 }, allow_nil: true
  # AddNicknameToUsers). The length cap is only to stop someone from stuffing a whole paragraph in
  # and breaking the table.
  validates :nickname, length: { maximum: 50 }, allow_nil: true

  # Which languages the user can pick on the switcher.
  SELECTABLE_LOCALES = %w[zh-CN en].freeze

  validates :locale, inclusion: { in: ->(_) { I18n.available_locales.map(&:to_s) } },
                     allow_nil: true

  # this one definition; the fallback rule should not be rewritten in each view.
  def display_name = nickname.presence || email_address

  def admin?     = role == "admin"
  def developer? = role == "developer"
  def ops?       = role == "ops"

  scope :active, -> { where(deactivated_at: nil) }

  def deactivated? = deactivated_at.present?

  # is actually kept out, and deactivation (resignation, permission revoked) is exactly the case
  # that can least afford to wait.
  def deactivate!
    transaction do
      update!(deactivated_at: Time.current)
      sessions.destroy_all
    end
  end

  def reactivate! = update!(deactivated_at: nil)
end
