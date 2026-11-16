class CreateAttentionAndStatusPage < ActiveRecord::Migration[8.1]
  def change
    # "Needs attention" items someone has acknowledged. Keyed by the item and the moment it started:
    # the same problem coming back later starts at another moment, so it shows again.
    create_table :dismissed_issues do |t|
      t.string :issue_key, null: false
      t.string :since, null: false
      t.references :user, foreign_key: true
      t.timestamps
    end
    add_index :dismissed_issues, [ :issue_key, :since ], unique: true

    # The public status page: which apps it lists, under what name, and one row per app and day
    # counting how many of the samples (every 10 minutes) found it working.
    add_column :managed_apps, :public_status, :boolean, null: false, default: false
    add_column :managed_apps, :public_name, :string
    create_table :status_samples do |t|
      t.references :managed_app, null: false, foreign_key: true
      t.date :day, null: false
      t.integer :total, null: false, default: 0
      t.integer :ok, null: false, default: 0
      t.integer :degraded, null: false, default: 0
      t.timestamps
    end
    add_index :status_samples, [ :managed_app_id, :day ], unique: true

    # Channels that also receive the Monday summary.
    add_column :notification_channels, :weekly_summary, :boolean, null: false, default: false
  end
end
