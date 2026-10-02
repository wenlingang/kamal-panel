class AddCreatedAtIndexToAuditLogs < ActiveRecord::Migration[8.1]
  def change
    add_index :audit_logs, :created_at
  end
end
