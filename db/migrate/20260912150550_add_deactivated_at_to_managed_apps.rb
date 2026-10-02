class AddDeactivatedAtToManagedApps < ActiveRecord::Migration[8.1]
  def change
    # 真删除被审计挡住：audit_logs 有一条指向 managed_apps 的外键，而审计行
    # 是设计上不可删除的（AuditLog#destroy/#delete/delete_all 全部抛异常）。
    # 和"用户只停用不删除"是同一个形状。
    add_column :managed_apps, :deactivated_at, :datetime
  end
end
