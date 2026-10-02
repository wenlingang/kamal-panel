class CreateProxyTargets < ActiveRecord::Migration[8.1]
  def change
    create_table :proxy_targets do |t|
      t.references :managed_app, null: false, foreign_key: true
      t.string   :host, null: false
      t.string   :service_name
      t.string   :target
      t.string   :state
      t.text     :raw
      t.datetime :observed_at, null: false
      t.datetime :created_at, null: false
    end

    add_index :proxy_targets, [ :managed_app_id, :observed_at ]
  end
end
