class User < ApplicationRecord
  ROLES = %w[admin developer ops].freeze

  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :app_memberships, dependent: :destroy
  has_many :managed_apps, through: :app_memberships

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  # 归一到 nil 而不是留下空串：「存了个空串」和「没填」在界面上长得一样，
  # 但会让 nickname.nil? 和 nickname.blank? 给出不同答案。只留一种空值。
  normalizes :nickname, with: ->(n) { n.strip.presence }

  validates :role, inclusion: { in: ROLES }
  # 唯一性此前只有数据库索引兜着：人员页填个重复邮箱会直接撞成 500，
  # 空邮箱则能存下一个永远登录不进来的账号。两条都得在模型层拦住。
  validates :email_address, presence: true, uniqueness: true
  # allow_nil 而不是 allow_blank：只改角色的 update 根本不碰 password，
  # 那时 password 是 nil，不该被这条长度校验拦下。而表单里留空提交的 ""
  # 是真的「想设密码却没填」，应该报错。
  validates :password, length: { minimum: 8 }, allow_nil: true
  # 不加唯一约束：昵称是显示名不是身份，重名是允许的（见迁移
  # AddNicknameToUsers）。长度上限只是防止有人把一整段话填进去撑坏表格。
  validates :nickname, length: { maximum: 50 }, allow_nil: true

  # 切换器上让用户选哪几种语言。设计 13 第 1 批建机制时它只有中文一项——
  # 界面还没翻完，给一个能切到半中半英的入口比不给更糟。五批全部翻完，
  # 这里放开英文，页头的切换器随之出现。
  SELECTABLE_LOCALES = %w[zh-CN en].freeze

  # 按 available_locales 校验，不是按 SELECTABLE_LOCALES——后者只管界面上
  # 让不让选，是个会随批次变的展示决定；数据库里能不能存是另一回事，不该
  # 因为界面暂时不暴露英文，就让已经存着 en 的行变成非法。
  validates :locale, inclusion: { in: ->(_) { I18n.available_locales.map(&:to_s) } },
                     allow_nil: true

  # 界面上称呼这个人的唯一出处。没填昵称就回落到邮箱——所有显示点共用
  # 这一个定义，回落规则不要在视图里各写一遍。
  def display_name = nickname.presence || email_address

  def admin?     = role == "admin"
  def developer? = role == "developer"
  def ops?       = role == "ops"

  scope :active, -> { where(deactivated_at: nil) }

  def deactivated? = deactivated_at.present?

  # 停用必须连带销毁会话：只写时间戳的话，已经登录的人要等到 cookie 过期
  # 才真的被挡在外面，而停用的场合（离职、权限收回）恰恰是最等不起的。
  def deactivate!
    transaction do
      update!(deactivated_at: Time.current)
      sessions.destroy_all
    end
  end

  def reactivate! = update!(deactivated_at: nil)
end
