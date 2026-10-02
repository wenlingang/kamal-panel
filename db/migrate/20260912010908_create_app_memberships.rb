class CreateAppMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :app_memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :managed_app, null: false, foreign_key: true
      t.datetime :created_at, null: false
    end

    # 唯一索引而不是只靠模型校验：成员关系是授权的输入，重复行会让
    # 「这个人是不是成员」这个问题在不同查询下给出不同答案。
    add_index :app_memberships, [ :user_id, :managed_app_id ], unique: true
  end
end
