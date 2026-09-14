class AddNicknameToUsers < ActiveRecord::Migration[8.1]
  # 可空，也不加唯一索引：昵称是显示名，不是身份。身份始终是 email_address
  # ——审计要追责时靠的是它，两个人叫同一个名字不该被数据库拦下。
  def change
    add_column :users, :nickname, :string
  end
end
