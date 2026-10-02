class OverviewsController < ApplicationController
  def show
    # that question (they are in the "Deactivated" group on the app list page).
    all_apps = ManagedApp.active.order(:name).to_a

    # What gets marked is [all] apps, not just the ones left after filtering.
    all_apps.each { |app| PollCadence.mark_viewed!(app) }

    @any_managed_apps = all_apps.any?
    @filter = OverviewFilter.new(q: params[:q], status: params[:status])
    @managed_apps = @filter.apply(all_apps)
    @statuses = @managed_apps.index_with { |app| ManagedAppStatus.new(app) }
  end
end
