# What an action was aimed at inside the app: an accessory name (accessory_restart/reboot) or a
# single host (restart --hosts). A column rather than detail_args because RunActionJob rebuilds the
# action from it, and the audit page shows it next to target_version.
class AddTargetToAuditLogs < ActiveRecord::Migration[8.1]
  def change
    add_column :audit_logs, :target, :string
  end
end
