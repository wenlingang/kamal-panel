# 两个凭据控制器共用的一句话：被引用的凭据删不掉时，告诉操作的人现在是什么
# 情况、以及他【真的能做】的是哪件事。
#
# 抽出来是因为它曾经在两个控制器里各写了一遍，而两份都写错了同一件事：
# 它们让人"先把应用换成别的凭据再删"，但 routes 里 managed_apps 只有
# index/new/create/show——接入之后面板根本没有改凭据的入口，这句指示做不到。
# 在 ManagedApp 有了编辑入口之前，这里只说真话：删不掉，但可以替换内容。
module BlockedCredentialAlert
  extend ActiveSupport::Concern

  private
    def blocked_destroy_alert(credential)
      apps = credential.managed_apps.map(&:name).join(t("common.list_separator"))

      t("flash.credential.blocked", name: credential.name, apps: apps,
                                    edit_path: edit_polymorphic_path(credential))
    end
end
