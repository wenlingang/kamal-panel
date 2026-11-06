# The actions tab and the quick actions (overview cards, app header). Buttons always render; these
# helpers decide whether one is usable and say why not, instead of hiding it.
module ActionsHelper
  # Lock state as the actions panel knows it:
  #   :reading  — placeholder while the lock frame loads (no SSH done yet)
  #   :free / :locked / :unknown — from KamalLock (:unknown when SSH or the read failed)
  #   :no_key   — the app has no SSH key, so nothing can run at all
  def lock_state_for(managed_app, read: false)
    return { state: :no_key } if managed_app.ssh_credential.nil?
    return { state: :reading } unless read

    lock = KamalLock.new(managed_app).status
    if lock[:error]
      { state: :unknown, error: lock[:error] }
    elsif lock[:locked]
      { state: :locked, details: lock[:details] }
    else
      { state: :free }
    end
  end

  # An unreadable lock does not disable anything: RunActionJob checks the lock again before running
  # and fails with a clear reason. Only a lock known to be held does.
  def action_disabled?(managed_app, action_class, lock)
    return true unless policy_for(managed_app).run?(action_class)
    return true if lock[:state] == :no_key

    lock[:state] == :locked && action_class.requires_lock?
  end

  # A button for an action that only needs the ordinary confirm dialog. The name and any extra
  # params go out as hidden fields; the server re-validates all of them.
  def action_button(managed_app, name, label, lock:, params: {}, confirm: nil, disabled: false, title: nil,
                    css: nil)
    action_class = Actions::Base.find(name)
    disabled ||= action_disabled?(managed_app, action_class, lock)

    button_to label, managed_app_actions_path(managed_app),
              method: :post, params: { name: name, **params }, class: css,
              disabled: disabled, title: title,
              form: { data: ({ turbo_confirm: confirm } if confirm && !disabled) }
  end

  # The version a restart from a quick action would boot: the one running version the observations
  # agree on. Database only, never SSH, so it is safe on the overview.
  def quick_restart_version(managed_app) = RollbackCandidates.new(managed_app).running_version

  # Why the quick restart can't be used right now, or nil when it can.
  def quick_restart_blocker(managed_app, version)
    if managed_app.ssh_credential.nil?
      t("quick_actions.restart_no_key")
    elsif version.nil?
      t("quick_actions.restart_unavailable")
    end
  end
end
