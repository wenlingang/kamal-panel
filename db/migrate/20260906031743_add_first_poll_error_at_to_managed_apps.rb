class AddFirstPollErrorAtToManagedApps < ActiveRecord::Migration[8.1]
  def change
    add_column :managed_apps, :first_poll_error_at, :datetime
  end
end
