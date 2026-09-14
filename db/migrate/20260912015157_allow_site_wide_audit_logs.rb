class AllowSiteWideAuditLogs < ActiveRecord::Migration[8.1]
  def change
    # 「改某人的角色」「停用某人」不属于任何应用。分成两张表意味着让事后查
    # 事故的人自己在脑子里做归并排序——而「谁在部署前五分钟把自己加进了这个
    # 应用」恰恰是最需要两类事件挨在一起才看得出来的。
    change_column_null :audit_logs, :managed_app_id, true

    add_reference :audit_logs, :target_user, null: true,
                  foreign_key: { to_table: :users }
  end
end
