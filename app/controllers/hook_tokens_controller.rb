# Generate / reset the reporting token.
class HookTokensController < ApplicationController
  def create
    app = ManagedApp.find(params[:managed_app_id])
    require_permission!(:regenerate_hook_token, app)
    return if performed?

    token = app.regenerate_hook_token!

    respond_to do |format|
      # Only put the dialog into the slot and do not refresh the page — the plaintext token appears
      # only this once, and re-rendering the whole page would interrupt someone who has just seen
      # the script with changes in scroll position and focus.
      format.turbo_stream { @managed_app, @token = app, token }
      # Without Turbo (JS disabled), fall back to a redirect; the token goes via flash and the view
      # renders it.
      format.html { redirect_to app, flash: { hook_token: token } }
    end
  end
end
