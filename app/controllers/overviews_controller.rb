class OverviewsController < ApplicationController
  def show
    # 那个问题（它们在应用列表页的"已停用"分组里）。
    all_apps = ManagedApp.active.order(:name).to_a

    # 标记的是【全部】应用，不是筛剩下的那几个。
    all_apps.each { |app| PollCadence.mark_viewed!(app) }

    @any_managed_apps = all_apps.any?
    @filter = OverviewFilter.new(q: params[:q], status: params[:status])
    @managed_apps = @filter.apply(all_apps)
    @statuses = @managed_apps.index_with { |app| ManagedAppStatus.new(app) }
  end
end
