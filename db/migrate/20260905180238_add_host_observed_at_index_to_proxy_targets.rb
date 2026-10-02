class AddHostObservedAtIndexToProxyTargets < ActiveRecord::Migration[8.1]
  def change
    # observations 早就有这个复合索引（迁移 20260905140247），proxy_targets
    # 跑的是逐字相同的 `group(:host).maximum(:observed_at)` 查询
    # （ProxyTarget.latest_for / PruneObservationsJob）却一直没有对应索引——
    # 两个兄弟表在索引上漂移了（final review M2）。
    add_index :proxy_targets, [ :managed_app_id, :host, :observed_at ],
      name: "index_proxy_targets_on_managed_app_id_and_host_and_observed_at"
  end
end
