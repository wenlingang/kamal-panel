class AddDeactivatedAtToManagedApps < ActiveRecord::Migration[8.1]
  def change
    # A real delete is blocked by auditing: audit_logs has a foreign key to managed_apps, and audit
    # rows are undeletable by design (AuditLog#destroy/#delete/delete_all all raise). Same shape as
    # "users are only deactivated, never deleted".
    add_column :managed_apps, :deactivated_at, :datetime
  end
end
