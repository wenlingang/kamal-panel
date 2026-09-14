class AddSshCredentialToManagedApps < ActiveRecord::Migration[8.1]
  def change
    add_reference :managed_apps, :ssh_credential, foreign_key: { to_table: :credentials }
  end
end
