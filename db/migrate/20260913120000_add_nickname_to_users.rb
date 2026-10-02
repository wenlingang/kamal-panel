class AddNicknameToUsers < ActiveRecord::Migration[8.1]
  # Nullable and no unique index: a nickname is a display name, not an identity. Identity is always
  # email_address; that's what accountability in audits relies on, and two people sharing a name
  # shouldn't be blocked by the database.
  def change
    add_column :users, :nickname, :string
  end
end
