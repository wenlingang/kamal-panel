class AddHookReportingToManagedApps < ActiveRecord::Migration[8.1]
  def change
    # 只存摘要：明文只在生成的那一次展示，面板自己也读不回来。
    add_column :managed_apps, :hook_token_digest, :string
    add_index  :managed_apps, :hook_token_digest, unique: true

    # 沿用 last_poll_error 那套模式：这是"当前配置有问题"的状态，
    # 不是需要留存的历史，所以不单独建表。
    add_column :managed_apps, :last_hook_rejection, :text
    add_column :managed_apps, :last_hook_rejection_at, :datetime
  end
end
