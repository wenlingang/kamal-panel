class ChangeUserRolesToThreeTier < ActiveRecord::Migration[8.1]
  # 一次性改值，不留兼容层。用 execute 而不是 User.update_all：迁移不该依赖
  # 模型当下的样子（ROLES 已经在同一个提交里变了，模型校验会跟数据打架）。
  def up
    execute "UPDATE users SET role = 'admin' WHERE role = 'operator'"
    execute "UPDATE users SET role = 'ops'   WHERE role = 'viewer'"
    # 默认值的含义是「没指定角色时给什么」，三档里权限最小的是 ops。
    change_column_default :users, :role, from: "viewer", to: "ops"
  end

  def down
    execute "UPDATE users SET role = 'operator' WHERE role = 'admin'"
    execute "UPDATE users SET role = 'viewer'   WHERE role = 'ops'"
    # developer 在旧模型里没有对应档位。回滚只能把它降到最小权限，
    # 而不是悄悄升成 operator。
    execute "UPDATE users SET role = 'viewer'   WHERE role = 'developer'"
    change_column_default :users, :role, from: "ops", to: "viewer"
  end
end
