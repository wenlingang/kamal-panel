class OverviewsController < ApplicationController
  VIEWS = %w[cards table].freeze

  def show
    # Deactivated apps are not part of "what does production look like right now"; they get their
    # own section below the grid.
    all_apps = ManagedApp.active.includes(:git_connection).order(:name).to_a

    # What gets marked is [all] apps, not just the ones left after filtering.
    all_apps.each { |app| PollCadence.mark_viewed!(app) }

    @any_managed_apps = all_apps.any?
    # Suggestions for the name filter (suggest_controller): every active app, not only the filtered ones.
    @app_names = all_apps.map(&:name)
    @deactivated_apps = ManagedApp.where.not(deactivated_at: nil).order(:name)

    # One status per app whose config parses, shared by the summary strip, the filter and the grid,
    # so each app's latest observations are read once. Apps with last_poll_error get none: computing
    # their level would re-parse the config and raise (see the comments in _grid).
    statuses = all_apps.reject { |app| app.last_poll_error.present? }
                       .index_with { |app| ManagedAppStatus.new(app) }

    @summary = summary_counts(all_apps, statuses)
    @filter = OverviewFilter.new(q: params[:q], status: params[:status])
    @managed_apps = @filter.apply(all_apps, statuses:)
    @statuses = statuses.slice(*@managed_apps)
    @view = params[:view].presence_in(VIEWS) || "cards"
  end

  private
    # { "drift" => 1, "ok" => 7, ..., "parse_error" => 0 } in OverviewFilter::STATUS_KEYS order.
    def summary_counts(apps, statuses)
      counts = statuses.values.map { |status| status.level.to_s }.tally
      counts[OverviewFilter::PARSE_ERROR] = apps.count { |app| app.last_poll_error.present? }

      OverviewFilter::STATUS_KEYS.index_with { |key| counts.fetch(key, 0) }
    end
end
