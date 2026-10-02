class CreateDeployEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :deploy_events do |t|
      t.references :managed_app, null: false, foreign_key: true
      t.string :version, null: false
      t.string :performer
      t.string :destination
      t.string :command
      t.string :source, null: false, default: "hook"

      # The moments the server received the two reports; all alert timing relies on these two
      # columns only
      t.datetime :started_at
      t.datetime :succeeded_at
      # The original text from the machine, used for display only
      t.datetime :recorded_at
      # Backfilled by polling: the observation time at which this version was first observed running
      t.datetime :observed_at

      t.timestamps
    end

    # Pairing query: the latest row for the same app and version where succeeded_at is null
    add_index :deploy_events, [ :managed_app_id, :version, :succeeded_at ]
    # Both alert queries and the history list fetch in reverse chronological order
    add_index :deploy_events, [ :managed_app_id, :created_at ]
  end
end
