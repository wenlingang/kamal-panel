class ApplicationController < ActionController::Base
  include Authentication
  # 必须在 Authentication 之后：resolved_locale 要读 Current.user，而
  # Current.session 是 Authentication 的 before_action 设上去的。
  include Localization
  allow_browser versions: :modern

  stale_when_importmap_changes

  POLICIES = {
    ManagedApp => ManagedAppPolicy,
    User => UserPolicy,
    Credential => CredentialPolicy,
    RegistryCredential => RegistryCredentialPolicy
  }.freeze

  # 声明式授权。用类宏而不是直接写 before_action，是为了让「这个动作要求什么
  # 权限」成为可读取的数据（authorization_rules）——Task 5 的结构性测试靠它
  # 发现漏挂过滤器的动作，而漏挂是这类重构最典型、且不会让任何别的测试变红
  # 的事故。
  class_attribute :authorization_rules, default: [], instance_writer: false

  def self.authorize(capability, on:, only:)
    self.authorization_rules = authorization_rules + [ { capability:, on:, only: Array(only) } ]
    before_action(only: only) { require_permission!(capability, on) }
  end

  helper_method :policy_for

  private
    def policy_for(record)
      klass = record.is_a?(Class) ? record : record.class
      POLICIES.fetch(klass).new(Current.user, record.is_a?(Class) ? nil : record)
    end

    def require_permission!(capability, record)
      return if policy_for(record).public_send("#{capability}?")

      redirect_to root_path, alert: t("flash.no_permission")
    end
end
