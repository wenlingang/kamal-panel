class AddLocaleToUsers < ActiveRecord::Migration[8.1]
  # 可空。NULL 表示「没表达过偏好」，跟默认语言走——这和「明确选了中文」
  # 是两件事：将来默认语言若改动，前者应该跟着变，后者不该。
  def change
    add_column :users, :locale, :string
  end
end
