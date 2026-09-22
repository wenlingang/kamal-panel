class ApplicationController < ActionController::Base
  include Authentication
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
