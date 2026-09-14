class CreateDeployEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :deploy_events do |t|
      t.references :managed_app, null: false, foreign_key: true
      t.string :version, null: false
      t.string :performer
      t.string :destination
      t.string :command
      t.string :source, null: false, default: "hook"

      # 服务端收到两段上报的时刻——所有告警计时只认这两列
      t.datetime :started_at
      t.datetime :succeeded_at
      # 机器上的原文，只用于展示
      t.datetime :recorded_at
      # 轮询回填：该版本首次被观测到 running 的观测时间
      t.datetime :observed_at

      t.timestamps
    end

    # 配对查询：同一应用同一版本中 succeeded_at 为空的最近一行
    add_index :deploy_events, [ :managed_app_id, :version, :succeeded_at ]
    # 告警查询与历史列表都按时间倒序取
    add_index :deploy_events, [ :managed_app_id, :created_at ]
  end
end
