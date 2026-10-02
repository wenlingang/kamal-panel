class CreateRegistryCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :registry_credentials do |t|
      t.string :name, null: false
      t.text :value, null: false
      # The registry's server is already in deploy.yml, and the panel doesn't need it to work. We
      # store it for one thing only: when picking a credential, compare it with the app config's
      # registry server and warn on a mismatch. So it's nullable, and it's a soft warning, not a
      # validation.
      t.string :server
      t.timestamps
    end

    add_index :registry_credentials, :name, unique: true
  end
end
