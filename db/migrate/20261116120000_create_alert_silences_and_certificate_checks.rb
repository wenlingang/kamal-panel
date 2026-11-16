class CreateAlertSilencesAndCertificateChecks < ActiveRecord::Migration[8.1]
  def change
    # A stretch of time when alerts for one app (or every app, managed_app_id nil) are not sent:
    # planned maintenance, or the app being in Kamal's maintenance mode (source "maintenance_mode",
    # open-ended until it goes live again).
    create_table :alert_silences do |t|
      t.references :managed_app, foreign_key: true
      t.references :user, foreign_key: true
      t.string :source, null: false, default: "manual"
      t.string :reason
      t.datetime :starts_at, null: false
      t.datetime :ends_at
      t.timestamps
    end
    add_index :alert_silences, [ :starts_at, :ends_at ]

    # The TLS certificate each app domain served when last looked at (CheckCertificatesJob).
    create_table :certificate_checks do |t|
      t.string :host, null: false
      t.datetime :not_after
      t.string :issuer
      t.text :error
      t.datetime :checked_at, null: false
      t.timestamps
    end
    add_index :certificate_checks, :host, unique: true
  end
end
