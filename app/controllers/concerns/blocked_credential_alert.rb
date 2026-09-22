module BlockedCredentialAlert
  extend ActiveSupport::Concern

  private
    def blocked_destroy_alert(credential)
      apps = credential.managed_apps.map(&:name).join(t("common.list_separator"))

      t("flash.credential.blocked", name: credential.name, apps: apps,
                                    edit_path: edit_polymorphic_path(credential))
    end
end
