# 一个 ManagedApp = 一份 deploy.yml + 一个 destination（spec 5.5）。
# 同一 repo 部署到 staging 与 production 是两个 ManagedApp。
#
# Kamal 的 load_raw_config 会把 deploy.<destination>.yml 深度合并（deep-merge）
# 到 deploy.yml 之上，很多真实项目就是靠这份 destination 覆盖文件给
# staging/production 配不同的 servers。所以 destination_config_yaml 必须
# 单独存一份，绝不能只存 config_yaml——否则面板会连错机器，这是这个产品
# 能犯的最坏错误。
#
# 领域上称「应用」；模型名避开 Application 以免与 Rails::Application 冲突。
class ManagedApp < ApplicationRecord
  belongs_to :ssh_credential, class_name: "Credential", optional: true
  belongs_to :registry_credential, optional: true
  has_many :app_memberships, dependent: :destroy
  has_many :members, through: :app_memberships, source: :user
  has_many :deploy_events, dependent: :destroy

  scope :active, -> { where(deactivated_at: nil) }

  # destination 最终会被当成文件名的一部分去拼路径（Kamal::ConfigParser
  # 需要一份 "deploy.<destination>.yml" 伴随文件，见 parsed_config 的注释），
  # 而且不只是本仓库自己拼——Kamal 内部定位那份伴随文件时做的是同一件事。
  # 如果 destination 里能有 "/" 或 ".."，就是一个路径穿越面：可以让父进程
  # 把 destination_config_yaml 写到临时目录之外的任意位置，也可以让子进程
  # 里的 Kamal 读到（并 ERB 求值）主机上任意一份已存在的 .yml 文件——都是
  # 在一条未认证的路由上（spec 7.2）。所以这里只放行短标识符：字母、数字、
  # 下划线、连字符，最多 63 个字符，跟真实 Kamal destination（production、
  # staging、eu-west……）的形状完全一致，不需要也不应该允许别的字符。
  # Kamal::ConfigParser 自己也会再校验一遍同样的形状（防御纵深：不能假设
  # 调用方一定会先校验），这里的校验只是为了给出友好的中文报错，而不是让
  # 用户看见一个文件系统层面的异常。两处校验，但只有一份正则定义——引用
  # Kamal::ConfigParser::DESTINATION_FORMAT，而不是在这里再抄一份字面量，
  # 避免两份正则将来悄悄漂移出不一致的形状。
  validates :destination, format: {
    with: Kamal::ConfigParser::DESTINATION_FORMAT,
    message: :invalid_format
  }, allow_blank: true

  validates :name, presence: true, uniqueness: true
  validates :config_yaml, presence: true
  validate :config_yaml_must_parse
  validate :ssh_credential_must_be_valid
  validate :kamal_hooks_must_be_valid
  validate :registry_secret_must_not_collide

  # Kamal 2.12.0 中 run_hook 的全部调用点（lib/kamal/cli/**）。这是一个封闭集合：
  # hook 文件名会被写进临时目录并【由 kamal 当作可执行文件执行】，所以名字不能
  # 是自由文本——否则它就是一个"往任意相对路径写可执行文件"的面。
  KAMAL_HOOK_NAMES = %w[
    docker-setup pre-build pre-connect pre-deploy post-deploy
    pre-app-boot post-app-boot pre-proxy-reboot post-proxy-reboot
  ].freeze

  # kamal_secrets / kamal_hooks：面板持有的那份 `.kamal/`。
  #
  # 为什么必须存在库里：Kamal 按【当前工作目录】相对路径解析 hooks_path
  # (".kamal/hooks") 与 secrets_path (".kamal/secrets")，见 kamal-2.12.0
  # configuration.rb:268-273。面板在一个临时目录里执行 kamal，用户的 repo 不在
  # 这台机器上（README：面板永不接触源码），所以除了面板自己把这两样东西写进
  # 那个临时目录，没有任何别的办法让它们可达。不写 → 用户的 pre/post-deploy
  # hook 永远不触发（而"让用户 hook 照常触发"正是我们选择调 CLI 而不是自己拼
  # 命令的理由），且 `registry.password: [KAMAL_REGISTRY_PASSWORD]` 这个 Kamal 2
  # 的标准写法会在 app boot / rollback 时直接报 Secret not found。
  #
  # 两列都加密：secrets 顾名思义；hook 脚本按 spec 5.4 的样例本身就带
  # per-application token。
  encrypts :kamal_secrets
  encrypts :kamal_hooks

  def deactivated? = deactivated_at.present?

  # 停用与释放凭据必须同生共死：只置空不停用，应用会继续被采集却没有钥匙；
  # 只停用不置空，被它占着的凭据照样删不掉——而"把应用整个拿下线"正是那些
  # 凭据能被删掉的唯一途径（设计 12 的删除守卫要求先解除引用）。
  def deactivate!
    transaction do
      update!(deactivated_at: Time.current, ssh_credential: nil, registry_credential: nil)
    end
  end

  # 只清时间戳。凭据要重新选一次——停用释放了绑定，启用就该重新决定给它哪把
  # 钥匙，而不是把一个可能已经被删掉的引用悄悄找回来。
  def reactivate! = update!(deactivated_at: nil)

  # {"pre-connect" => "#!/bin/sh\n..."}。这里做的是"读的一侧要宽容"：内容坏了
  # 就当成没有 hook，而不是让一次回滚在读配置时抛异常——真正的报错发生在
  # 保存时（kamal_hooks_must_be_valid）。
  def kamal_hooks_scripts
    parsed = JSON.parse(kamal_hooks.to_s)
    return {} unless parsed.is_a?(Hash)

    parsed.select { |name, body| KAMAL_HOOK_NAMES.include?(name) && body.is_a?(String) && body.present? }
  rescue JSON::ParserError
    {}
  end

  # 上报 token 只存摘要（spec 03 第 3 节）。明文在 regenerate 时返回一次，
  # 之后无论是面板还是数据库泄露都拿不回来——与 SSH 私钥的"只写不读"一致。
  #
  # 用 update_columns 而不是 update!：这里绕过校验不是图省事，而是必须——
  # config_yaml_must_parse / ssh_credential_must_be_valid 校验的是记录存下
  # 之后才可能失效的东西（Kamal 升级导致旧配置解析不过、共用凭据被改坏）。
  # 怀疑 token 泄露、需要立刻轮换，恰恰是配置或凭据可能已经损坏的时刻——
  # 这时候如果轮换本身也要求"整个应用当前 valid?"，就会把最该能用的
  # 应急操作锁死。与 reject_hook! 同一套模式：外部触发的状态写入不该
  # 因为模型整体是否 valid 而失败。
  def regenerate_hook_token!
    token = SecureRandom.urlsafe_base64(32)
    update_columns(hook_token_digest: self.class.hook_token_digest_for(token), updated_at: Time.current)
    token
  end

  def hook_reporting_enabled? = hook_token_digest.present?

  def reject_hook!(message)
    update_columns(last_hook_rejection: message.to_s.truncate(500),
                   last_hook_rejection_at: Time.current)
  end

  def self.hook_token_digest_for(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  def self.find_by_hook_token(token)
    return nil if token.blank?

    find_by(hook_token_digest: hook_token_digest_for(token))
  end

  def parsed_config
    @parsed_config ||= Kamal::ConfigParser.call(
      yaml: config_yaml,
      destination: destination,
      destination_yaml: destination_config_yaml
    )
  end

  def service
    parsed_config.service
  end

  def app_hosts
    parsed_config.app_hosts
  end

  def role_names
    parsed_config.role_names
  end

  # 高频渲染路径（总览页、应用列表）只需要主机列表，不需要完整
  # parsed_config，但 app_hosts 背后仍然是一次 parsed_config 子进程调用。
  # 用「app id + 决定解析结果的三个字段的内容摘要」做缓存键，而不是
  # updated_at：这样缓存只在 config_yaml/destination/destination_config_yaml
  # 真正变化时才失效，而不是每次保存（哪怕内容没变）就失效，也不会在
  # 内容变了但 updated_at 没变——反过来——时悄悄提供旧值。这是一份缓存，
  # 不是又一份需要手动同步的持久化数据：Rails.cache 本身可以随时被清空，
  # 清空后按同样的键重新计算，结果不变。
  def cached_app_hosts
    Rails.cache.fetch(app_hosts_cache_key) { app_hosts }
  end

  # config_yaml / destination_config_yaml / destination 变更后都必须让缓存
  # 失效，否则会拿旧解析结果去连新机器。
  def config_yaml=(value)
    @parsed_config = nil
    super
  end

  def destination_config_yaml=(value)
    @parsed_config = nil
    super
  end

  def destination=(value)
    @parsed_config = nil
    super
  end

  # ActiveRecord#reload rewrites the underlying attributes directly, bypassing the
  # writers above entirely — without this override a reloaded record would keep
  # serving a parse of whatever config_yaml/destination it had *before* the reload,
  # which is the exact "polling the wrong machine" failure this cache-invalidation
  # scheme exists to prevent.
  def reload(*)
    @parsed_config = nil
    super
  end

  private
    def config_yaml_must_parse
      return if config_yaml.blank?
      return if errors[:destination].any? # destination 已经不合法，不必再触发一次解析

      parsed_config
    rescue Kamal::ConfigParser::ParseError => e
      # e.message 本身不翻：同一条解析错误还会被写进 last_poll_error
      # （持久化列），按设计 13 §2.1 那种内容一律保持原样。只翻前缀。
      errors.add(:config_yaml, :unparseable, reason: e.message)
    end

    # belongs_to 默认不校验关联对象（只有 has_one/has_many 默认校验），如果不显式
    # 处理，一个校验失败的 Credential（比如格式不对的私钥）会在 save 时被静默丢弃：
    # ManagedApp 照样保存成功，但 ssh_credential_id 是 nil，用户完全看不到任何报错——
    # 处理密钥这种敏感输入时这是不可接受的。这里手写校验而不是 `belongs_to ...,
    # validate: true`，是为了给出中文错误信息（而不是默认的英文 "is invalid"），
    # 且不把 Credential#value 本身（私钥原文）带进错误信息。
    def ssh_credential_must_be_valid
      return if ssh_credential.nil?
      return if ssh_credential.valid?

      errors.add(:ssh_credential, :invalid_key,
                 reason: ssh_credential.errors[:value].join(I18n.t("common.error_separator")))
    end

    def kamal_hooks_must_be_valid
      return if kamal_hooks.blank?

      parsed = JSON.parse(kamal_hooks)
      raise JSON::ParserError, "不是 JSON 对象" unless parsed.is_a?(Hash)

      unknown = parsed.keys - KAMAL_HOOK_NAMES
      if unknown.any?
        errors.add(:kamal_hooks, :unknown_hooks,
                   names: unknown.join(I18n.t("common.list_separator")))
      end
      errors.add(:kamal_hooks, :hook_not_a_string) unless parsed.values.all? { |v| v.is_a?(String) }
    rescue JSON::ParserError
      errors.add(:kamal_hooks, :not_a_json_object)
    end

    # 两处都定义同一个变量时拒绝保存。无论让哪一边赢，都会在部署时安静地
    # 用错一个密码，而失败现场（拉不动镜像）离原因很远——在人还能改的时候
    # 大声失败，是这个仓库一贯的做法。
    def registry_secret_must_not_collide
      return if registry_credential.nil? || kamal_secrets.blank?
      # 配置本身解析不了时，另一条校验（config_yaml_must_parse）会报错，
      # 这里不重复报，也不能去调解析。destination 不合法时同理：
      # config_yaml_must_parse 在那种情况下【压根没去解析】，errors[:config_yaml]
      # 是空的，而 ConfigParser 会因为那个 destination 当场抛 ParseError——
      # 少这一行，一次本该变成表单报错的保存会变成 500。
      return if errors[:config_yaml].any? || errors[:destination].any?

      env = parsed_config.registry_password_env
      return if env.blank?

      return unless kamal_secrets.match?(/^\s*#{Regexp.escape(env)}\s*=/)

      errors.add(:kamal_secrets, :registry_secret_collision, env: env)
    end

    def app_hosts_cache_key
      # 用 NUL 分隔而不是空格：三段内容本身可能任意长且包含任意空白，用一个在 YAML/标识符里几乎不可能出现的分隔符，避免"字段边界挪动但拼接结果凑巧相同"导致缓存键碰撞。
      digest = Digest::SHA256.hexdigest(
        [ config_yaml, destination, destination_config_yaml ].join("\u0000")
      )

      "managed_app/#{id}/app_hosts/#{digest}"
    end
end
