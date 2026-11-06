# What the log query form shows for one app: the choices that app offers and the current values,
# taken from the URL. Lenient where LogQuery is strict: a value that doesn't fit the app (a source
# from the previously selected app, a host of another source, a window someone typed by hand)
# falls back to the default here, so switching apps just works; whatever reaches LogQuery from the
# results URL is still validated there.
class LogQueryForm
  WINDOWS = LogQuery::WINDOWS.keys.freeze

  attr_reader :managed_app, :source, :host, :since, :lines, :keyword, :case_sensitive, :version

  def initialize(managed_app, params)
    @managed_app = managed_app
    @sources = LogQuery.sources_for(managed_app.parsed_config)
    source = @sources.find { |candidate| candidate.key == params[:source].to_s } || @sources.first
    @source = source.key
    @host = params[:host].to_s.presence_in(source.hosts)
    @versions = source.kind.in?(%i[app role]) ? LogQuery.versions_for(managed_app) : []
    @version = params[:version].to_s.presence_in(@versions.map { |entry| entry[:version] })
    # An old version's container usually stopped longer ago than any window, so "all" is both
    # offered and the default once a version is chosen; without one it isn't valid at all.
    @since = params[:since].to_s.presence_in(windows) || (version ? LogQuery::ALL_TIME : LogQuery::DEFAULT_WINDOW)
    @lines = params[:lines].to_i.presence_in(LogQuery::LINE_LIMITS) || LogQuery::DEFAULT_LINES
    @keyword = params[:q].to_s.first(LogQuery::MAX_KEYWORD_LENGTH).presence
    @case_sensitive = params[:case] == "1"
  end

  attr_reader :sources, :versions

  def windows = version ? [ *WINDOWS, LogQuery::ALL_TIME ] : WINDOWS

  # Follow mode tails what is running now; a chosen version may well be stopped.
  def followable? = version.nil?

  def current_source = sources.find { |source| source.key == self.source }

  def hosts = current_source.hosts

  # The query part of the results URL (and of the shareable /logs URL), defaults left out. Pass it
  # as `params:` to a path helper: as plain options, `host:` would be taken as the URL's host.
  def query_params
    {
      app: managed_app.id,
      source: (source unless source == "app"),
      host: host,
      version: version,
      since: (since unless since == (version ? LogQuery::ALL_TIME : LogQuery::DEFAULT_WINDOW)),
      lines: (lines unless lines == LogQuery::DEFAULT_LINES),
      q: keyword,
      case: ("1" if case_sensitive)
    }.compact
  end
end
