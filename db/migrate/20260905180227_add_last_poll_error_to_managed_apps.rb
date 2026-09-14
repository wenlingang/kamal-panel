class AddLastPollErrorToManagedApps < ActiveRecord::Migration[8.1]
  def change
    add_column :managed_apps, :last_poll_error, :text
    add_column :managed_apps, :last_poll_error_at, :datetime
  end
end
