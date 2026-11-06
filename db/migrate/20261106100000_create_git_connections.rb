class CreateGitConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :git_connections do |t|
      t.string :name, null: false
      t.string :provider, null: false
      t.string :api_url, null: false
      t.string :web_url, null: false
      # Encrypted (GitConnection encrypts :token); text because the ciphertext envelope is longer than the token.
      t.text :token, null: false
      t.timestamps
    end
    add_index :git_connections, :name, unique: true

    change_table :managed_apps, bulk: true do |t|
      t.references :git_connection, foreign_key: true
      t.string :repository
      t.string :git_branch
      t.string :version_format, null: false, default: "sha"
    end
  end
end
