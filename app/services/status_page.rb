# What the public status page shows: the listed apps under their public names, how each is doing
# now and its last DAYS days. Deliberately nothing else (no hosts, versions, logs or alert text):
# anyone on the internet can read it.
class StatusPage
  DAYS = 30

  Row = Data.define(:name, :level, :days, :uptime)

  def self.enabled? = ManagedApp.active.where(public_status: true).exists?

  # :ok / :degraded / :down / :unknown for one app's collected state.
  def self.level_of(status)
    case status.level
    when :ok then :ok
    when :unhealthy, :drift then :degraded
    when :unreachable then :down
    else :unknown
    end
  end

  def initialize(today: Date.current)
    @today = today
  end

  def rows
    @rows ||= begin
      apps = ManagedApp.active.where(public_status: true).order(Arel.sql("COALESCE(public_name, name)")).to_a
      samples = StatusSample.where(managed_app: apps, day: range).group_by(&:managed_app_id)

      apps.map do |app|
        by_day = samples.fetch(app.id, []).index_by(&:day)
        days = range.map { |day| [ day, by_day[day] ] }
        recorded = days.filter_map(&:last)
        total = recorded.sum(&:total)
        uptime = total.zero? ? nil : recorded.sum { |sample| sample.ok + sample.degraded }.fdiv(total)
        level = app.last_poll_error.present? ? :down : self.class.level_of(ManagedAppStatus.new(app))

        Row.new(name: app.public_name.presence || app.name, level:, days:, uptime:)
      end
    end
  end

  # The banner: everything fine, something degraded, or something down.
  def overall
    levels = rows.map(&:level)
    if levels.include?(:down) then :down
    elsif levels.include?(:degraded) then :degraded
    elsif levels.all?(:ok) then :ok
    else :unknown
    end
  end

  def range = (today - (DAYS - 1))..today

  private
    attr_reader :today
end
