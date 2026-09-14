class CreateObservations < ActiveRecord::Migration[8.1]
  def change
    create_table :observations do |t|
      t.references :managed_app, null: false, foreign_key: true
      t.string   :host, null: false
      t.string   :role
      t.string   :container_name
      t.string   :version
      t.string   :docker_status
      t.string   :health
      t.boolean  :reachable, null: false, default: true
      t.string   :error
      t.datetime :observed_at, null: false
      t.datetime :created_at, null: false
    end

    add_index :observations, [ :managed_app_id, :observed_at ]
    add_index :observations, [ :managed_app_id, :host, :observed_at ]
  end
end
