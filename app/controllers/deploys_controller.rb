# The global deploy page (spec 6): recent deploys across active apps, and the entry point for a
# new one. Reading it is open to everyone signed in, like the overview and each app's history;
# deploying itself is checked per app (AppDeploysController).
class DeploysController < ApplicationController
  def index
    @apps = ManagedApp.active.order(:name)
    @app_id = params[:app_id].presence&.to_i
    scope = @app_id ? @apps.where(id: @app_id) : @apps
    @entries = DeployFeed.new(scope).entries
    # Output links follow the output page's own check (run? on a deploy = act?), computed once.
    @deployable_ids = deployable_apps.to_set(&:id)
  end

  # Pick the app; its deploy tab takes it from there.
  def new
    @apps = deployable_apps
  end

  private
    def deployable_apps
      ManagedApp.active.order(:name).includes(:members, :git_connection).select { |app| policy_for(app).act? }
    end
end
