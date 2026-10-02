class CreateRegistryCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :registry_credentials do |t|
      t.string :name, null: false
      t.text :value, null: false
      # registry 的 server 已经在 deploy.yml 里，面板不需要它才能工作。存它
      # 只为一件事：选凭据时和应用配置里的 registry server 比一下，不一致就
      # 提示。所以可空，而且是软提示不是校验。
      t.string :server
      t.timestamps
    end

    add_index :registry_credentials, :name, unique: true
  end
end
