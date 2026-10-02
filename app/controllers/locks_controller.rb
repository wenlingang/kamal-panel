# Deploy lock status. Read-only, visible to all three roles — it decides "whether this app can be
# touched right now".
class LocksController < ApplicationController
  def show
    @managed_app = ManagedApp.find(params[:managed_app_id])
    require_permission!(:show, @managed_app)
    return if performed?

    render layout: false
  end
end
