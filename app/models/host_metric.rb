# One host's load, memory and root-disk usage in one collection minute, as seen by one app's
# collection. Scoped to the app on purpose (see the migration): a host shared by several apps is
# sampled once per app, which costs a few rows but means no app reads numbers another app's SSH
# config produced. The unique index on app + host + minute makes a repeated round a no-op.
class HostMetric < ApplicationRecord
  belongs_to :managed_app

  validates :host, :sampled_at, presence: true

  def readonly?
    persisted?
  end

  def mem_used_percent
    return nil if mem_total_bytes.to_i.zero? || mem_available_bytes.nil?

    100.0 * (mem_total_bytes - mem_available_bytes) / mem_total_bytes
  end

  def mem_used_bytes
    mem_total_bytes - mem_available_bytes if mem_total_bytes && mem_available_bytes
  end

  def disk_used_percent
    return nil if disk_total_bytes.to_i.zero? || disk_used_bytes.nil?

    100.0 * disk_used_bytes / disk_total_bytes
  end

  def swap_used_bytes
    swap_total_bytes - swap_free_bytes if swap_total_bytes && swap_free_bytes
  end
end
