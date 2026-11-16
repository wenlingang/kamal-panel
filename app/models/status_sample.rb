# One app's day on the public status page: of `total` samples (StatusPageSampleJob, every 10
# minutes), how many found it working (`ok`) and how many found it degraded (unhealthy containers or
# versions that disagree, but up). The rest found it down or unreachable.
class StatusSample < ApplicationRecord
  belongs_to :managed_app

  def down = total - ok - degraded

  # nil for a day with no samples (before the app was listed).
  def uptime = total.zero? ? nil : (ok + degraded).fdiv(total)

  # The day's colour on the strip: the worst it got, weighed so one bad sample isn't a red day.
  def level
    return :unknown if total.zero?
    return :down if down.fdiv(total) >= 0.1
    return :degraded if down.positive? || degraded.fdiv(total) >= 0.1

    :ok
  end
end
