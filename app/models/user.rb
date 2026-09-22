class User < ApplicationRecord
  ROLES = %w[admin developer ops].freeze

  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :app_memberships, dependent: :destroy
  has_many :managed_apps, through: :app_memberships

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  # 但会让 nickname.nil? 和 nickname.blank? 给出不同答案。只留一种空值。
  normalizes :nickname, with: ->(n) { n.strip.presence }

  validates :role, inclusion: { in: ROLES }
  # 空邮箱则能存下一个永远登录不进来的账号。两条都得在模型层拦住。
  validates :email_address, presence: true, uniqueness: true
  validates :password, length: { minimum: 8 }, allow_nil: true
  # AddNicknameToUsers）。长度上限只是防止有人把一整段话填进去撑坏表格。
  validates :nickname, length: { maximum: 50 }, allow_nil: true

  # 切换器上让用户选哪几种语言。
  SELECTABLE_LOCALES = %w[zh-CN en].freeze

  validates :locale, inclusion: { in: ->(_) { I18n.available_locales.map(&:to_s) } },
                     allow_nil: true

  # 这一个定义，回落规则不要在视图里各写一遍。
  def display_name = nickname.presence || email_address

  def admin?     = role == "admin"
  def developer? = role == "developer"
  def ops?       = role == "ops"

  scope :active, -> { where(deactivated_at: nil) }

  def deactivated? = deactivated_at.present?

  # 才真的被挡在外面，而停用的场合（离职、权限收回）恰恰是最等不起的。
  def deactivate!
    transaction do
      update!(deactivated_at: Time.current)
      sessions.destroy_all
    end
  end

  def reactivate! = update!(deactivated_at: nil)
end
