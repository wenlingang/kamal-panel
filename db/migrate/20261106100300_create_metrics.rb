# Resource metrics: one row per container per minute (per app), one row per host per minute.
#
# Both tables are append-only samples pruned after PruneObservationsJob::METRICS_RETENTION. The
# unique indexes make a sample idempotent: sampled_at is truncated to the minute, so a second
# collection in the same minute (an overlapping job, or another app sharing the host) is skipped
# by insert_all instead of doubling the series.
class CreateMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :container_metrics do |t|
      t.references :managed_app, null: false, foreign_key: true, index: false
      t.string :host, null: false
      t.string :container_name, null: false
      # Role name for app containers, accessory name for accessories, "kamal-proxy" for the proxy.
      t.string :source, null: false
      t.string :kind, null: false
      t.string :version
      t.float :cpu_percent
      t.bigint :mem_bytes
      # nil when the container has no memory limit (docker then reports the host's total).
      t.bigint :mem_limit_bytes
      t.float :mem_percent
      t.bigint :net_rx_bytes
      t.bigint :net_tx_bytes
      t.bigint :block_read_bytes
      t.bigint :block_write_bytes
      t.integer :pids
      t.datetime :sampled_at, null: false
    end
    add_index :container_metrics, [ :managed_app_id, :sampled_at ]
    add_index :container_metrics, [ :managed_app_id, :host, :container_name, :sampled_at ],
              unique: true, name: "index_container_metrics_unique_sample"
    add_index :container_metrics, :sampled_at

    # Host samples belong to the app whose collection wrote them. The host string alone is not an
    # identity: two apps can name the same "10.1.0.11" yet reach different machines (port, proxy,
    # user are per-app config that app members edit), so sharing samples by host string would let
    # one app's config feed — or suppress alerts on — another app's host readings.
    create_table :host_metrics do |t|
      t.references :managed_app, null: false, foreign_key: true
      t.string :host, null: false
      t.float :load1
      t.float :load5
      t.float :load15
      t.integer :cpus
      # Derived from the /proc/stat delta against the previous sample of the same host; nil for
      # the first sample (or after a gap / reboot).
      t.float :cpu_percent
      t.bigint :cpu_total_jiffies
      t.bigint :cpu_idle_jiffies
      t.bigint :mem_total_bytes
      t.bigint :mem_available_bytes
      t.bigint :swap_total_bytes
      t.bigint :swap_free_bytes
      t.bigint :disk_total_bytes
      t.bigint :disk_used_bytes
      t.datetime :sampled_at, null: false
    end
    add_index :host_metrics, [ :managed_app_id, :host, :sampled_at ], unique: true
    add_index :host_metrics, :sampled_at
  end
end
