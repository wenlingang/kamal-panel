# Log rows for the centralized log page. Built with tag helpers rather than a per-row partial: a
# query can return 5000 rows, and every piece of log text goes through the helpers' escaping —
# nothing from a log line is ever marked html_safe.
module LogsHelper
  # Host tags get a colour each (not a status colour: a host isn't good or bad for being host 2).
  HOST_COLORS = 6

  def log_host_class(host, hosts) = "log-host-#{(hosts.index(host) || 0) % HOST_COLORS}"

  def log_source_label(source)
    case source.kind
    when :app then t("logs.sources.app")
    when :role then t("logs.sources.role", name: source.name)
    when :accessory then t("logs.sources.accessory", name: source.name)
    when :proxy then t("logs.sources.proxy")
    end
  end

  def log_keyword_pattern(keyword, case_sensitive)
    return nil if keyword.blank?

    Regexp.new(Regexp.escape(keyword), case_sensitive ? nil : Regexp::IGNORECASE)
  end

  def log_rows(entries, hosts:, pattern:)
    safe_join(entries.map { |entry| log_row(entry, hosts:, pattern:) })
  end

  def log_row(entry, hosts:, pattern:)
    tag.div(class: [ "log-row", ("lvl-#{entry.level}" if entry.level) ]) do
      safe_join([
        log_time(entry.time),
        tag.span(entry.host, class: [ "log-host", log_host_class(entry.host, hosts) ]),
        tag.span(entry.source, class: "log-source"),
        tag.span(highlight_log_keyword(entry.line, pattern), class: "log-line")
      ])
    end
  end

  # Panel time zone (Beijing by default), to the millisecond; the full instant on hover.
  def log_time(time)
    return tag.span("—", class: "log-time") if time.nil?

    tag.time(l(time.in_time_zone, format: :log), datetime: time.utc.iso8601(9), class: "log-time",
                                                 title: time.in_time_zone.iso8601(3))
  end

  # Wraps each keyword hit in <mark>. The pieces are plain strings, escaped by safe_join.
  def highlight_log_keyword(text, pattern)
    return text if pattern.nil?

    pieces = []
    position = 0
    text.scan(pattern) do
      match = Regexp.last_match
      next if match[0].empty?

      pieces << text[position...match.begin(0)]
      pieces << tag.mark(match[0])
      position = match.end(0)
    end
    pieces << text[position..]
    safe_join(pieces)
  end

  def log_error_message(error)
    message = t("logs.errors.#{error.kind}")
    return message if error.detail.blank?

    t("logs.errors.with_detail", message:, detail: error.detail)
  end
end
