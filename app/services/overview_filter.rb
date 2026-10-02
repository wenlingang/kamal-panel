# Filter criteria for the overview page (fuzzy name match + status).
class OverviewFilter
  PARSE_ERROR = "parse_error"

  # The set of options in the dropdown.
  STATUS_KEYS = (ManagedAppStatus::LEVELS.map(&:to_s) + [ PARSE_ERROR ]).freeze

  # The dropdown [display name, value] pairs, translated only at call time. The view feeds them
  # straight to options_for_select.
  def self.options
    STATUS_KEYS.map { |key| [ label_for(key), key ] }
  end

  def self.label_for(key)
    key == PARSE_ERROR ? I18n.t("statuses.parse_error") : ManagedAppStatus.label_for(key)
  end

  attr_reader :q, :status

  def initialize(q: nil, status: nil)
    @q = q.to_s.strip
    # The params come from the URL, which anyone can edit by hand. Also do not hand over an empty
    # page of "nothing at all" that makes people think apps were lost.
    @status = status.to_s.presence_in(STATUS_KEYS)
  end

  def active?
    q.present? || status.present?
  end

  def apply(managed_apps)
    apps = managed_apps
    apps = apps.select { |app| app.name.downcase.include?(q.downcase) } if q.present?
    apps = apps.select { |app| matches_status?(app) } if status

    apps
  end

  private
    def matches_status?(app)
      # that row to compute level — computing it would raise ParseError right away.
      return app.last_poll_error.present? if status == PARSE_ERROR
      return false if app.last_poll_error.present?

      ManagedAppStatus.new(app).level.to_s == status
    end
end
