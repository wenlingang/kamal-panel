# Centralized logs (spec §7). index is the page shell (form + an empty results frame), so it
# renders at once; results does the SSH work and fills the frame, and also answers follow mode's
# increments. Querying is view_logs? on the app (spec §9); queries are read-only and frequent, so
# they are not audited, but they are rate limited per user.
class LogsController < ApplicationController
  # One query per user per 2 seconds (spec §7). Follow mode polls every 3 seconds, so it fits.
  rate_limit to: 1, within: 2.seconds, only: :results, by: -> { Current.user.id }, name: "log-query",
             with: -> { render_rate_limited }

  def index
    @apps = queryable_apps
    return if params[:app].blank?

    @managed_app = ManagedApp.find(params[:app])
    require_permission!(:view_logs, @managed_app)
    return if performed?

    @form = LogQueryForm.new(@managed_app, params) if @managed_app.last_poll_error.blank?
  rescue Kamal::ConfigParser::ParseError
    @form = nil
  end

  def results
    @managed_app = ManagedApp.find(params[:app])
    require_permission!(:view_logs, @managed_app)
    return if performed?

    @query = LogQuery.new(@managed_app, source: params[:source], host: params[:host], since: params[:since],
                                        lines: params[:lines], grep: params[:q], case_sensitive: params[:case],
                                        seen: params[:seen], version: params[:version])
    @result = @query.call

    if params[:follow].present?
      render partial: "logs/batch", locals: { query: @query, result: @result }
    else
      render layout: false
    end
  rescue LogQuery::InvalidQuery, Kamal::ConfigParser::ParseError
    render_problem(t("logs.results.invalid"), :unprocessable_entity)
  end

  private
    # The apps this person may read logs of, whose config parses (nothing to query otherwise).
    def queryable_apps
      ManagedApp.active.order(:name).includes(:members)
                .select { |app| app.last_poll_error.blank? && policy_for(app).view_logs? }
    end

    def render_rate_limited
      render_problem(t("logs.results.rate_limited"), :too_many_requests)
    end

    # Follow mode reads only the status; the frame shows the message in place of the results.
    def render_problem(message, status)
      if params[:follow].present?
        head status
      else
        render partial: "logs/problem", locals: { message: }, status: status
      end
    end
end
