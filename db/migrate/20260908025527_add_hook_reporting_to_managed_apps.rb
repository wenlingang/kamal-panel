class AddHookReportingToManagedApps < ActiveRecord::Migration[8.1]
  def change
    # Store only the digest: the plaintext is shown just once, when generated, and the panel itself
    # can't read it back.
    add_column :managed_apps, :hook_token_digest, :string
    add_index  :managed_apps, :hook_token_digest, unique: true

    # Follows the last_poll_error pattern: this is a "current config is broken" state,
    # not history worth keeping, so it doesn't get its own table.
    add_column :managed_apps, :last_hook_rejection, :text
    add_column :managed_apps, :last_hook_rejection_at, :datetime
  end
end
