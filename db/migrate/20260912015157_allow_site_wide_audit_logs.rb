class AllowSiteWideAuditLogs < ActiveRecord::Migration[8.1]
  def change
    # "Change someone's role" and "deactivate someone" belong to no app. Splitting into two tables
    # means making whoever investigates an incident after the fact do a merge sort in their head,
    # and "who added themselves to this app five minutes before the deploy" is exactly what only
    # shows up when both kinds of events sit side by side.
    change_column_null :audit_logs, :managed_app_id, true

    add_reference :audit_logs, :target_user, null: true,
                  foreign_key: { to_table: :users }
  end
end
