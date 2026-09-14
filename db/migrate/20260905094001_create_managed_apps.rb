class CreateManagedApps < ActiveRecord::Migration[8.1]
  def change
    create_table :managed_apps do |t|
      t.string :name, null: false
      t.text   :config_yaml, null: false
      t.text   :destination_config_yaml
      t.string :destination
      t.timestamps
    end

    add_index :managed_apps, :name, unique: true
  end
end
