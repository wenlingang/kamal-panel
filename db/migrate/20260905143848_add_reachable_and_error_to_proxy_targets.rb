class AddReachableAndErrorToProxyTargets < ActiveRecord::Migration[8.1]
  def change
    add_column :proxy_targets, :reachable, :boolean, default: true, null: false
    add_column :proxy_targets, :error, :string
  end
end
