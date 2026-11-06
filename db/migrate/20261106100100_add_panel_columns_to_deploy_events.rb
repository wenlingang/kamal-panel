class AddPanelColumnsToDeployEvents < ActiveRecord::Migration[8.1]
  def change
    change_table :deploy_events, bulk: true do |t|
      # Only panel deploys can know they failed: Kamal has no failure hook, so hook rows never set it.
      t.datetime :failed_at
      # The audit row whose output belongs to this attempt (panel deploys and rollbacks only).
      t.references :audit_log, foreign_key: true
    end
  end
end
