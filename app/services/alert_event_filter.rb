# Filter criteria and paging for the alert history (app + state, newest first). Same shape as
# AuditLogFilter: values from the URL that match nothing are dropped, and paging is an id cursor so
# a new event doesn't shift the pages.
class AlertEventFilter
  PER_PAGE = 50

  Page = Data.define(:entries, :next_before)

  attr_reader :app_id, :state

  def initialize(app_id: nil, state: nil, before: nil)
    @app_id = ManagedApp.exists?(id: app_id.presence) ? app_id.to_i : nil
    @state = state.to_s.presence_in(AlertEvent::STATES)
    @before = Integer(before, exception: false)
  end

  def active? = app_id.present? || state.present?

  def page
    scope = AlertEvent.includes(:alert_rule, :managed_app).order(id: :desc)
    scope = scope.where(managed_app_id: app_id) if app_id
    scope = scope.where(state:) if state
    scope = scope.where("alert_events.id < ?", @before) if @before

    rows = scope.limit(PER_PAGE + 1).to_a
    entries = rows.first(PER_PAGE)
    Page.new(entries:, next_before: rows.size > PER_PAGE ? entries.last.id : nil)
  end
end
