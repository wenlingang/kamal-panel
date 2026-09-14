require "digest"
require "base64"

# 加密存储的 SSH 私钥。
#
# 只写不读（spec 7.2）：UI 永不回显私钥、不提供下载，编辑只能整体替换。
# 因此本模型对外只暴露 fingerprint，value 仅供采集器内部使用。
#
# 安全说明：value 在认证功能上线之前，是在**未认证**的路由上被校验的
# （创建 ManagedApp 不需要登录）——也就是说任何人都可以把任意字节当成
# "私钥" 提交上来，而这些字节需要被喂给 net-ssh 这个第三方解析器才能
# 知道它是不是一把可用的私钥。net-ssh 解析时可能触达 OpenSSL/bcrypt，
# 真正的解密/KDF 尝试要花多久，完全由私钥里攻击者可控的字段决定（比如
# OpenSSH 私钥格式的 bcrypt rounds、PKCS#8 的 iteration count）。
#
# 早先的做法是：解密前自己先读一遍私钥 header，看 cipher/kdf 是不是
# "none"，试图跳过整个解析。这制造了一个"自制 reader 必须和 net-ssh
# 对同一段字节的理解永远一致"的双重解析器问题——而且真的出过一次 bypass：
# 给每一行 base64 都加上 "-----" 前缀，自制 reader 按行过滤掉这些前缀后
# 看到空 body，判定"不是 OpenSSH 私钥，放行"；net-ssh 内部按固定偏移切片、
# 再用宽松的 `unpack1("m")`（忽略非 base64 字符，包括 "-"）解码，却仍然
# 照常解出 cipher=aes256-ctr、kdf=bcrypt，并真的去跑攻击者指定 rounds 的
# bcrypt。硬化自制 reader 直到和 net-ssh 逐字节一致，只会换来"下一次
# net-ssh 升级就可能再次不一致"。
#
# 所以现在改用本仓库 Kamal::ConfigParser 解析 deploy.yml 已经验证过的
# 边界：不试图预判/复刻第三方解析器会做什么，而是把解析放进
# SshKeyValidator（独立子进程 + 硬超时）里跑——无论 net-ssh 做了什么、
# 花了多久，超时了父进程就直接 kill 子进程。这样就不需要判断"这次输入
# 会不会触发某个具体的耗时路径"，任何 net-ssh 解析漏洞（现在的，或者
# 未来 net-ssh 升级引入的）都被同一个超时挡住。
#
# 带密码的私钥仍然会被拒绝，但这是产品要求，不是这里的 DoS 防线：面板要
# 无人值守地建立 SSH 连接，没有人能在场输入密码，所以带密码的私钥本来就
# 不可用，拒绝是正确行为，与它是否也恰好比较耗时无关。
class Credential < ApplicationRecord
  include WriteOnlySecret

  KINDS = %w[ssh_key].freeze

  # 真实的 SSH 私钥从几百字节到几 KB 不等；16 KiB 已经非常宽裕。这个上限
  # 在做任何解析（哪怕是子进程里的）之前生效，子进程超时守住的是"解析
  # 要花多久"，这里守住的是"输入本身有多大"，两者互补。
  MAX_VALUE_BYTES = 16 * 1024

  # 共享池里的凭据被引用时不能删：删完把引用置空，会让好几个应用静默变成
  # "没有私钥"，而操作的人看不到任何提示。要删就先把引用它的应用换掉。
  has_many :managed_apps, foreign_key: :ssh_credential_id, dependent: :restrict_with_error,
           inverse_of: :ssh_credential

  validates :kind, inclusion: { in: KINDS }
  validate :value_within_size_limit
  validate :value_must_be_a_private_key

  # fingerprint 在保存时算好、存进一个明文列，而不是在每次展示时都现算：
  # 现算意味着每次访问 show 页面都要再解密一次 value、再跑一次
  # SshKeyValidator 子进程——而 fingerprint 本身是确定性的、非秘密的值，
  # 没有理由每次读都重新付一次子进程的开销，也没有理由为了读它而碰
  # 密文。这里复用的是校验时（value_must_be_a_private_key）已经跑过的
  # 那次 SshKeyValidator 结果（下面 validation_result 的记忆化），所以
  # 保存时不会多花一次子进程调用。
  before_save :store_fingerprint, if: :will_save_change_to_value?

  def fingerprint
    super || backfill_fingerprint
  end

  private
    def store_fingerprint
      self.fingerprint = validation_result&.fingerprint
    end

    # 兜底：只处理"这一行是 fingerprint 列加上去之前就存在的旧记录"这一种
    # 情况——不是每次读都重算，只在列里是 nil 的时候现算一次并回填，回填
    # 之后这一行就跟正常保存的记录没有区别了，以后再也不用重算。如果
    # 现算也失败（比如密文损坏、密钥根本解不出来），不报错，只退回展示
    # "（无法读取指纹）"。
    def backfill_fingerprint
      computed = validation_result&.fingerprint
      update_column(:fingerprint, computed) if computed.present? && persisted?
      computed.presence || I18n.t("credentials.fingerprint_unreadable")
    end

    # 校验（value_must_be_a_private_key）、store_fingerprint、
    # backfill_fingerprint 都需要同一次子进程校验结果；这里按 value 记忆化
    # （比较内容而不是对象身份——加密属性的 getter 可能在不同时刻返回内容
    # 相同但不是同一个对象的 String，用 `.equal?` 会让记忆化形同虚设），
    # 保证每个实例、每个不同的 value，子进程最多跑一次。
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
