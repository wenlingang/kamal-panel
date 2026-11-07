# A session's lifetime on the server, not just in the cookie. Before this, a session lived as long
# as its cookie, and cookies were permanent; the browser deciding when to drop a cookie (session
# restore brings "session" cookies back) is not something a panel that can restart production
# should rely on.
#
# Existing sessions were all created as "permanent". They get the remember-me lifetime from now,
# rather than being cut off at deploy or left permanent.
class AddExpiresAtToSessions < ActiveRecord::Migration[8.1]
  def up
    add_column :sessions, :expires_at, :datetime
    execute "UPDATE sessions SET expires_at = #{connection.quote(30.days.from_now)}"
    change_column_null :sessions, :expires_at, false
  end

  def down
    remove_column :sessions, :expires_at
  end
end
