class OverviewsController < ApplicationController
  VIEWS = %w[cards table].freeze

  def show
    # Deactivated apps are not part of "what does production look like right now"; they get their
    # own section below the grid.
    all_apps = ManagedApp.active.includes(:git_connection).order(:name).to_a

    # Deliberately does not mark apps as viewed (PollCadence.mark_viewed!): the overview shows every
    # app, so speeding them all up would make an overview left open all day poll the whole fleet at
    # status.viewing, overriding status.idle — the deployer's setting (config/collection.yml) would
    # only hold while nobody looked. The page shows what the configured cadence collects, refreshed
    # by OverviewSignal after each round. Opening one app's page still speeds up that app.
    @any_managed_apps = all_apps.any?
    # Suggestions for the search box (suggest_controller): every active app's name and domains, not
    # only the filtered ones.
    @app_names = all_apps.map(&:name) + suggested_domains(all_apps)
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
    # Apps with last_poll_error are skipped: their domains would need a parse that raises.
    def suggested_domains(apps)
      apps.reject { |app| app.last_poll_error.present? }
          .flat_map { |app| app.cached_domains.map { |domain| domain[:host] } }
          .uniq
    rescue Kamal::ConfigParser::ParseError
      []
    end
    # { "drift" => 1, "ok" => 7, ..., "parse_error" => 0 } in OverviewFilter::STATUS_KEYS order.
    def summary_counts(apps, statuses)
      counts = statuses.values.map { |status| status.level.to_s }.tally
      counts[OverviewFilter::PARSE_ERROR] = apps.count { |app| app.last_poll_error.present? }

      OverviewFilter::STATUS_KEYS.index_with { |key| counts.fetch(key, 0) }
    end
end
