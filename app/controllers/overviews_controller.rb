class OverviewsController < ApplicationController
  def show
    # 只列未停用的：这一页回答的是"现在线上是什么样"，停用的应用不属于
    # 那个问题（它们在应用列表页的"已停用"分组里）。
    all_apps = ManagedApp.active.order(:name).to_a

    # 标记的是【全部】应用，不是筛剩下的那几个。筛选是"我现在只想看这几行"，
    # 不是"其余的不用采了"——跟着筛选走，会让人一筛就把其他应用的采集悄悄
    # 降到 IDLE，而那恰恰是出问题时最不该发生的事。
    all_apps.each { |app| PollCadence.mark_viewed!(app) }

    @any_managed_apps = all_apps.any?
    @filter = OverviewFilter.new(q: params[:q], status: params[:status])
    @managed_apps = @filter.apply(all_apps)
    @statuses = @managed_apps.index_with { |app| ManagedAppStatus.new(app) }
  end
end
