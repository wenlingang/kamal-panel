# Alerting (spec 8): where notifications go, what to watch for, and what happened.
class CreateAlerting < ActiveRecord::Migration[8.1]
  def change
    create_table :notification_channels do |t|
      t.string :name, null: false
      t.string :kind, null: false
      # Encrypted (NotificationChannel encrypts both). A Slack / Feishu webhook URL is itself the
      # credential: whoever has it can post to the channel.
      t.text :target, null: false
      t.text :secret
      t.boolean :enabled, null: false, default: true
      # The last delivery attempt's outcome, shown on the settings page so a broken webhook is noticed
      # before the alert that matters.
      t.datetime :last_delivered_at
      t.text :last_error
      t.datetime :last_error_at
      t.timestamps
    end
    add_index :notification_channels, :name, unique: true

    create_table :alert_rules do |t|
      t.string :name, null: false
      # NULL = every active app.
      t.references :managed_app, foreign_key: true
      t.string :condition, null: false
      t.json :params, null: false, default: {}
      t.integer :for_minutes, null: false, default: 2
      t.boolean :enabled, null: false, default: true
      # Log-keyword rules only: when the last log scan was claimed, and why the last one couldn't
      # read the logs (if it couldn't).
      t.datetime :last_evaluated_at
      t.text :last_error
      t.datetime :last_error_at
      t.timestamps
    end

    create_table :alert_rule_channels do |t|
      t.references :alert_rule, null: false, foreign_key: true
      t.references :notification_channel, null: false, foreign_key: true
    end
    add_index :alert_rule_channels, %i[alert_rule_id notification_channel_id], unique: true

    create_table :alert_events do |t|
      t.references :alert_rule, null: false, foreign_key: true
      t.references :managed_app, null: false, foreign_key: true
      t.string :state, null: false
      # Rendered at display / send time (like AuditLog detail_key / detail_args), so the page shows
      # it in the viewer's language.
      t.string :message_key, null: false
      t.json :message_args, null: false, default: {}
      t.string :dedupe_key
      t.datetime :started_at, null: false
      t.datetime :fired_at
      t.datetime :resolved_at
      t.datetime :last_notified_at
      t.timestamps
    end
    add_index :alert_events, %i[state started_at]
    add_index :alert_events, %i[managed_app_id state]
    # The database-level guard against overlapping evaluations: at most one open (pending / firing)
    # state event per rule and app, and one event per source record for event-type rules.
    add_index :alert_events, %i[alert_rule_id managed_app_id], unique: true,
              where: "state IN ('pending', 'firing') AND dedupe_key IS NULL",
              name: "index_alert_events_one_open_per_rule_and_app"
    add_index :alert_events, %i[alert_rule_id dedupe_key], unique: true,
              where: "dedupe_key IS NOT NULL",
              name: "index_alert_events_one_per_source_record"
  end
end
