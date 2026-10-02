class AddHostObservedAtIndexToProxyTargets < ActiveRecord::Migration[8.1]
  def change
    # observations has long had this composite index (migration 20260905140247), while proxy_targets
    # runs the verbatim same `group(:host).maximum(:observed_at)` query
    # (ProxyTarget.latest_for / PruneObservationsJob) yet never had a matching index;
    # the two sibling tables drifted apart on indexes (final review M2).
    add_index :proxy_targets, [ :managed_app_id, :host, :observed_at ],
      name: "index_proxy_targets_on_managed_app_id_and_host_and_observed_at"
  end
end
