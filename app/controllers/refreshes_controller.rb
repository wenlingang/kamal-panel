# Manually trigger one collection.
class RefreshesController < ApplicationController
  def create
    managed_app = ManagedApp.find(params[:managed_app_id])

    PollCadence.mark_burst!(managed_app)
    PollManagedAppJob.perform_later(managed_app)

    respond_to do |format|
      # comes back — so this step does not refresh the whole page.
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "host-status",
          partial: "managed_apps/refreshing"
        )
      end
      format.html { redirect_to managed_app }
    end
  end
end
