class AddConvergenceTrackingToManagedApps < ActiveRecord::Migration[8.1]
  def change
    # nil 表示"还没建立基线"：第一次收敛只写这两列、不产生事件。
    # 一个早就在跑某一版的应用刚被接进面板，它不是"今天部署的"。
    add_column :managed_apps, :last_converged_version, :string
    # 存的是观测时刻（那批 running 观测里最早的 observed_at），不是 Time.current——
    # 与 Reconciler 回填 observed_at 用观测时间是同一条理由。
    add_column :managed_apps, :last_converged_at, :datetime
  end
end
