class AddFingerprintToCredentials < ActiveRecord::Migration[8.1]
  def change
    add_column :credentials, :fingerprint, :string
  end
end
