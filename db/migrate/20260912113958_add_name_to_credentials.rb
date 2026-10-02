class AddNameToCredentials < ActiveRecord::Migration[8.1]
  # Backfill with raw SQL rather than the model: the model just gained a required validation on name
  # in the same commit, and using it to write these still-unnamed rows would fight the validation.
  def up
    add_column :credentials, :name, :string

    taken = Set.new

    select_all(<<~SQL).each do |row|
      SELECT c.id AS id,
             (SELECT m.name FROM managed_apps m
               WHERE m.ssh_credential_id = c.id ORDER BY m.id LIMIT 1) AS app_name
        FROM credentials c
       ORDER BY c.id
    SQL
      base = row["app_name"].presence ? "#{row["app_name"]} 的 SSH 私钥" : "未命名凭据 #{row["id"]}"
      # ManagedApp#name has no unique constraint, so two apps sharing a name is possible, and the
      # next step is to add a unique index on name. On conflict, append the id as a suffix.
      name = taken.include?(base) ? "#{base}（##{row["id"]}）" : base
      taken << name

      execute("UPDATE credentials SET name = #{quote(name)} WHERE id = #{row["id"].to_i}")
    end

    change_column_null :credentials, :name, false
    add_index :credentials, :name, unique: true
  end

  def down
    remove_index :credentials, :name
    remove_column :credentials, :name
  end
end
