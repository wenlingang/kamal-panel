class AddNameToCredentials < ActiveRecord::Migration[8.1]
  # 回填用原始 SQL 而不是模型：模型在同一个提交里刚加上 name 的必填校验，
  # 用它来写这批还没有名字的行会跟校验打架。
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
      # ManagedApp#name 没有唯一约束，两个应用同名是可能的——而下一步就要给
      # name 加唯一索引。冲突时补 id 后缀。
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
