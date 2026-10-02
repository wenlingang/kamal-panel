class AddRegistryCredentialToManagedApps < ActiveRecord::Migration[8.1]
  def change
    add_reference :managed_apps, :registry_credential, null: true, foreign_key: true
  end
end
