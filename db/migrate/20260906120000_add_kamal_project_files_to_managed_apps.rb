class AddKamalProjectFilesToManagedApps < ActiveRecord::Migration[8.1]
  # Kamal resolves both `.kamal/secrets*` and `.kamal/hooks/*` relative to the [current working
  # directory] (kamal-2.12.0 configuration.rb:268-273). The panel runs kamal in a temp directory, so
  # the panel itself must own these two things and write them into that temp directory; otherwise
  # the user's hooks never fire, and `app boot`/`rollback` inevitably fail with the standard
  # array-style password syntax.
  #
  # Both columns are encrypted: secrets, obviously; the hook scripts, per the sample in spec 5.4,
  # themselves carry a per-application token, which is likewise credential material.
  def change
    add_column :managed_apps, :kamal_secrets, :text
    add_column :managed_apps, :kamal_hooks, :text
  end
end
