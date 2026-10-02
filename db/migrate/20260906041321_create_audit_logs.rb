class CreateAuditLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :audit_logs do |t|
      t.references :user, null: false, foreign_key: true
      t.references :managed_app, null: false, foreign_key: true
      t.string   :action_name, null: false
      t.string   :target_version
      t.text     :hosts
      t.text     :command
      t.text     :output_digest
      t.string   :result, null: false, default: "pending"
      t.integer  :duration_ms
      t.datetime :created_at, null: false
      t.datetime :finished_at
    end

    add_index :audit_logs, [ :managed_app_id, :created_at ]
  end
end
