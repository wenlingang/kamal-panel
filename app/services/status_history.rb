# The heartbeat strip: an app's last N collection rounds, one cell each, coloured by that round's
# level. It answers "has it been like this for a while", which the single status badge cannot.
#
# What counts as a round: Collectors::ContainerCollector stamps every row it inserts in one call
# (every host, every container) with the same observed_at, taken once when the collector is built.
# So rows sharing an observed_at are exactly one round across all hosts, and grouping by it needs
# no time-window guessing. A round whose deploy.yml could not be parsed inserts nothing, so it
# simply does not appear (the overview says "config cannot be parsed" on its own).
#
# Deliberately config-free: it never touches parsed_config, so it is safe to render for an app
# whose last poll hit a parse error (see the comments in overviews/_grid). That is also why a
# past round's level comes from ManagedAppStatus.round_level, which leaves out the two checks that
# only make sense for "now": staleness, and hosts that today's deploy.yml lists.
class StatusHistory
  DEFAULT_ROUNDS = 40

  # observed_at and level are both nil for a placeholder (history shorter than the strip).
  # badge_key refines the wording within a level, like ManagedAppStatus#badge_key: a round where
  # every failing host answered with unreadable output is not "host unreachable".
  Cell = Data.define(:observed_at, :level, :badge_key) do
    def placeholder? = observed_at.nil?
  end

  # A round that was not ok, with every row it recorded (newest round first, see #problem_rounds).
  # All rows, not just the failing ones: drift is only visible next to the hosts that disagree.
  Round = Data.define(:observed_at, :level, :badge_key, :rows)

  # The columns the level and wording read, plus what the problem-rounds list shows per row.
  COLUMNS = %i[observed_at host role container_name reachable docker_status health version error].freeze

  attr_reader :rounds

  def initialize(managed_app, rounds: DEFAULT_ROUNDS)
    @managed_app = managed_app
    @rounds = rounds
  end

  # Oldest first, padded on the left with placeholders up to `rounds` cells.
  def cells
    @cells ||= begin
      recorded = rounds_by_time.map do |round|
        Cell.new(observed_at: round.observed_at, level: round.level, badge_key: round.badge_key)
      end

      Array.new(rounds - recorded.size) { Cell.new(observed_at: nil, level: nil, badge_key: nil) } + recorded
    end
  end

  def recorded_cells = cells.reject(&:placeholder?)

  # How many recorded rounds were not ok: the strip's caption, so the history is not colour-only.
  def problem_count = recorded_cells.count { |cell| cell.level != :ok }

  # The rounds behind problem_count, newest first: what the strip's caption links to.
  def problem_rounds = rounds_by_time.reject { |round| round.level == :ok }.reverse

  # Anchor of one round in the problem-rounds list, shared by the list and the strip's cells.
  def self.round_anchor(observed_at) = "round-#{observed_at.to_i}"

  private
    attr_reader :managed_app

    # Oldest first.
    def rounds_by_time
      @rounds_by_time ||= rows.group_by(&:observed_at).sort_by(&:first).map do |observed_at, round_rows|
        level = ManagedAppStatus.round_level(round_rows)
        Round.new(observed_at:, level:, badge_key: badge_key(level, round_rows),
                  rows: round_rows.sort_by { |row| [ row.host.to_s, row.container_name.to_s ] })
      end
    end

    def badge_key(level, round_rows)
      return level.to_s unless level == :unreachable

      failed = round_rows.reject(&:reachable)
      marker = Collectors::ContainerCollector::UNPARSEABLE_OUTPUT_MARKER
      failed.all? { |row| row.error.to_s.include?(marker) } ? "unparseable" : "unreachable"
    end

    # One query, bounded: the rows of the newest `rounds` distinct observed_at values. The IN
    # subquery (DISTINCT ... ORDER BY ... LIMIT) runs on the (managed_app_id, observed_at) index.
    def rows
      scope = Observation.where(managed_app_id: managed_app.id)
      latest_rounds = scope.distinct.order(observed_at: :desc).limit(rounds).select(:observed_at)

      scope.where(observed_at: latest_rounds).select(*COLUMNS).to_a
    end
end
