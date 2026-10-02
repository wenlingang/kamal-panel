class CreateAppMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :app_memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :managed_app, null: false, foreign_key: true
      t.datetime :created_at, null: false
    end

    # A unique index rather than relying only on model validation: membership is an input to
    # authorization, and duplicate rows would make the question "is this person a member" answer
    # differently under different queries.
    add_index :app_memberships, [ :user_id, :managed_app_id ], unique: true
  end
end
