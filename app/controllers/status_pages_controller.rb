# The public status page at /status: no sign-in, nothing but the apps an operator chose to list
# (managed_apps.public_status) and how they're doing. 404 when no app is listed, so a panel that
# doesn't use it doesn't advertise it.
class StatusPagesController < ApplicationController
  allow_unauthenticated_access
  layout "status"

  def show
    raise ActionController::RoutingError, "Not Found" unless StatusPage.enabled?

    @page = StatusPage.new
    expires_in 1.minute, public: true
  end
end
