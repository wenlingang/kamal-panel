# Filter criteria and paging for the audit list (app + actor + result, newest first).
class AuditLogFilter
  PER_PAGE = 50

  # The app dropdown's value for entries that belong to no app (people, credentials).
  SITE_WIDE = "site_wide"

  Page = Data.define(:entries, :next_before)

  attr_reader :app_id, :user_id, :result

  # Params come from the URL and anyone can edit them by hand: values that match nothing are
  # dropped rather than producing an empty page that looks like the log was lost.
  def initialize(app_id: nil, user_id: nil, result: nil, before: nil)
    @app_id = normalize_app_id(app_id)
    @user_id = User.exists?(id: user_id.presence) ? user_id.to_i : nil
    @result = result.to_s.presence_in(AuditLog::RESULTS)
    @before = Integer(before, exception: false)
  end

  def active?
    app_id.present? || user_id.present? || result.present?
  end

  # The cursor is the id, not a page number: a new entry arriving while someone pages back would
  # otherwise shift every page by one and show a row twice.
  def page
    scope = AuditLog.includes(:user, :managed_app, :target_user).order(id: :desc)
    scope = scope.where(managed_app_id: app_id == SITE_WIDE ? nil : app_id) if app_id
    scope = scope.where(user_id:) if user_id
    scope = scope.where(result:) if result
    scope = scope.where("audit_logs.id < ?", @before) if @before

    rows = scope.limit(PER_PAGE + 1).to_a
    entries = rows.first(PER_PAGE)
    Page.new(entries:, next_before: rows.size > PER_PAGE ? entries.last.id : nil)
  end

  private
    def normalize_app_id(value)
      return SITE_WIDE if value == SITE_WIDE

      ManagedApp.exists?(id: value.presence) ? value.to_i : nil
    end
end
