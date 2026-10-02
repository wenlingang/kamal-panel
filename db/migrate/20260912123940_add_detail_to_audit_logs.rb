class AddDetailToAuditLogs < ActiveRecord::Migration[8.1]
  def change
    # A human-readable "to whom / about what". The target_user_id added in design 11 can only point
    # at a user, and a credential is not a user. Credential events use this to record the credential
    # name.
    add_column :audit_logs, :detail, :string
  end
end
