class CreateCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :credentials do |t|
      t.string :kind, null: false, default: "ssh_key"
      t.text   :value, null: false # encrypted by ActiveRecord encryption

      t.timestamps
    end
  end
end
