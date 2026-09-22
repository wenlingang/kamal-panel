# 一个 ManagedApp = 一份 deploy.yml + 一个 destination（spec 5.5）。
class ManagedApp < ApplicationRecord
  belongs_to :ssh_credential, class_name: "Credential", optional: true
  belongs_to :registry_credential, optional: true
  has_many :app_memberships, dependent: :destroy
  has_many :members, through: :app_memberships, source: :user
  has_many :deploy_events, dependent: :destroy

  scope :active, -> { where(deactivated_at: nil) }

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

  # Kamal 2.12.0 中 run_hook 的全部调用点（lib/kamal/cli/**）。
  KAMAL_HOOK_NAMES = %w[
    docker-setup pre-build pre-connect pre-deploy post-deploy
    pre-app-boot post-app-boot pre-proxy-reboot post-proxy-reboot
  ].freeze

  # 面板永不接触源码，所以除了它自己把这两样写进临时目录，没别的办法让它们可达。
  encrypts :kamal_secrets
  encrypts :kamal_hooks

  def deactivated? = deactivated_at.present?

  # 停用与释放凭据必须同生共死：只置空不停用，应用会继续被采集却没有钥匙；
  def deactivate!
    transaction do
      update!(deactivated_at: Time.current, ssh_credential: nil, registry_credential: nil)
    end
  end

  # 钥匙，而不是把一个可能已经被删掉的引用悄悄找回来。
  def reactivate! = update!(deactivated_at: nil)

  # {"pre-connect" => "#!/bin/sh\n..."}。这里做的是"读的一侧要宽容"：内容坏了
  def kamal_hooks_scripts
    parsed = JSON.parse(kamal_hooks.to_s)
    return {} unless parsed.is_a?(Hash)

    parsed.select { |name, body| KAMAL_HOOK_NAMES.include?(name) && body.is_a?(String) && body.present? }
  rescue JSON::ParserError
    {}
  end

  # 上报 token 只存摘要（spec 03 第 3 节）。
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

  def cached_app_hosts
    Rails.cache.fetch(app_hosts_cache_key) { app_hosts }
  end

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
      # （持久化列），按设计 13 §2.1 那种内容一律保持原样。只翻前缀。
      errors.add(:config_yaml, :unparseable, reason: e.message)
    end

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

    def registry_secret_must_not_collide
      return if registry_credential.nil? || kamal_secrets.blank?
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
