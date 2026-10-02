class LocalesController < ApplicationController
  # Takes no user id: there is no "switch the language for someone else" path, so there is no object
  # that needs authorization. This is also why it has no policy — the only thing that can be changed
  # is one's own.
  def update
    Current.user.update(locale: params[:locale])

    # Which page to go back to: if it is unavailable or is an external site, we only ever fall back
    # to the home page.
    redirect_back fallback_location: root_path
  end
end
