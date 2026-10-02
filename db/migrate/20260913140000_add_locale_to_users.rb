class AddLocaleToUsers < ActiveRecord::Migration[8.1]
  # Nullable. NULL means "never expressed a preference" and follows the default language; this is
  # different from "explicitly chose Chinese": if the default language changes later, the former
  # should follow along and the latter shouldn't.
  def change
    add_column :users, :locale, :string
  end
end
