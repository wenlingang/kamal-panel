class ChangeUserRolesToThreeTier < ActiveRecord::Migration[8.1]
  # One-off value change, no compatibility layer. Use execute rather than User.update_all: a
  # migration shouldn't depend on what the model looks like right now (ROLES already changed in the
  # same commit, so model validation would fight the data).
  def up
    execute "UPDATE users SET role = 'admin' WHERE role = 'operator'"
    execute "UPDATE users SET role = 'ops'   WHERE role = 'viewer'"
    # The meaning of the default is "what to give when no role is specified"; the least privileged
    # of the three tiers is ops.
    change_column_default :users, :role, from: "viewer", to: "ops"
  end

  def down
    execute "UPDATE users SET role = 'operator' WHERE role = 'admin'"
    execute "UPDATE users SET role = 'viewer'   WHERE role = 'ops'"
    # developer had no corresponding tier in the old model. A rollback can only demote it to the
    # least privilege, rather than quietly promoting it to operator.
    execute "UPDATE users SET role = 'viewer'   WHERE role = 'developer'"
    change_column_default :users, :role, from: "ops", to: "viewer"
  end
end
