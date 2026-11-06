require "digest"
require "json"
require "securerandom"
require "shellwords"

# The centralized log query (spec §7): one app, one source (all app roles, one role, an accessory or
# kamal-proxy), all of that source's hosts or one of them, a time window, a per-host line limit and
# an optional fixed-string keyword. Runs `docker logs` over SSH on every host at once and merges the
# lines into one timeline.
#
# Every input is checked against a whitelist (InvalidQuery otherwise); container names come from
# the parsed config or the latest observations, never from the request; the keyword is the only
# free text and reaches the shell only through Shellwords.escape, after `-e` and before `--`, so it
# can't turn into an option either.
#
# Also the building block for log-keyword alert rules (spec §8): see #call.
class LogQuery
  class InvalidQuery < StandardError; end

  WINDOWS = {
    "5m" => 5.minutes, "15m" => 15.minutes, "1h" => 1.hour, "6h" => 6.hours, "24h" => 24.hours
  }.freeze
  DEFAULT_WINDOW = "15m".freeze
  # Only with a chosen version: an old version's container was usually stopped by the deploy that
  # replaced it, often longer ago than the widest window, so its whole (tail-limited) log is fair game.
  ALL_TIME = "all".freeze
  # Same charset Actions validate versions against; the value is also matched against observations.
  VERSION = /\A\w[\w.-]{0,127}\z/
  # The oldest absolute `since` accepted (follow mode and alert rules pass one): the same reach as the
  # widest window, so an absolute time can't be used to scan a host's whole log history.
  MAX_LOOKBACK = 24.hours + 5.minutes

  LINE_LIMITS = [ 200, 500, 1000 ].freeze
  DEFAULT_LINES = 200

  MAX_KEYWORD_LENGTH = 200
  # Caps on what one query returns, whatever the hosts send: the page renders every row.
  MAX_ENTRIES = 5000
  MAX_BYTES = 2.megabytes
  MAX_LINE_BYTES = 8.kilobytes
  MAX_SEEN_KEYS = 200

  EXECUTION_TIMEOUT = 15 # seconds per host; the hosts run in parallel
  MAX_THREADS = 8

  PROXY_CONTAINER = "kamal-proxy".freeze
  # Docker's own container-name rule. Names come from our config or our observations, but they are
  # still spliced into a shell command, so they are checked as well as escaped.
  CONTAINER_NAME = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,254}\z/
  SEEN_KEY = /\A\h{16}\z/

  # `docker logs --timestamps` prefixes each line with an RFC3339Nano time and one space.
  TIMESTAMPED_LINE = /\A(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})) ?(.*)\z/m
  ANSI_ESCAPE = /\e\[[\d;?]*[A-Za-z]/

  # kind: :app (every role), :role, :accessory, :proxy. label: what each line is tagged with.
  Source = Data.define(:key, :kind, :name, :hosts)

  Entry = Data.define(:time, :host, :source, :line, :level) do
    # Identifies a line across two queries, for follow mode's boundary dedupe. Short: it travels in
    # the URL.
    def key
      Digest::SHA256.hexdigest([ host, source, time&.utc&.iso8601(9), line ].join("\0"))[0, 16]
    end
  end

  # kind: :no_credential (host nil), :unreachable, :no_container (nothing running — or, with a version,
  # nothing of that version — per the latest observations), :container_missing, :container_stopped, :failed
  HostError = Data.define(:host, :kind, :detail)

  # cursor: the newest line's time (or the query time when nothing came back); boundary_keys: the
  # keys of the lines at exactly the cursor. Follow mode sends both back as since= and seen=.
  Result = Data.define(:entries, :errors, :hosts, :truncated, :duration_ms, :cursor, :boundary_keys) do
    def host_count = hosts.size
  end

  # The sources an app offers, in the order the form lists them. Per-role sources only when there is
  # more than one role: with one, "app" already is that role.
  def self.sources_for(config)
    sources = [ Source.new(key: "app", kind: :app, name: nil, hosts: config.app_hosts) ]
    if config.roles.size > 1
      config.roles.each do |role|
        sources << Source.new(key: "app:#{role[:name]}", kind: :role, name: role[:name], hosts: Array(role[:hosts]))
      end
    end
    config.accessories.each do |accessory|
      sources << Source.new(key: "accessory:#{accessory[:name]}", kind: :accessory, name: accessory[:name],
                            hosts: Array(accessory[:hosts]))
    end
    sources << Source.new(key: "proxy", kind: :proxy, name: PROXY_CONTAINER, hosts: config.app_hosts)
  end

  # The app versions whose containers the latest observations still see on the app's hosts, running
  # ones first: Kamal keeps the containers of previous deploys stopped (for rollback) until a prune,
  # and their logs stay readable with them. [{ version:, running: }]
  def self.versions_for(managed_app, observations = Observation.latest_for(managed_app).to_a)
    observations.select { |o| o.version.present? && VERSION.match?(o.version) }
                .group_by(&:version)
                .map { |version, rows| { version:, running: rows.any? { |o| o.docker_status == "running" } } }
                .sort_by { |entry| [ entry[:running] ? 0 : 1, entry[:version] ] }
  end

  # Cheap on purpose: it runs on every line. JSON logs say their level outright; otherwise the
  # conventional markers (Ruby Logger's "E, [", upper-case ERROR/WARN, logfmt level=, exception
  # class names).
  ERROR_PATTERNS = [
    /\b(?:ERROR|FATAL|CRITICAL|PANIC)\b/,
    /\A[EF], \[/,
    /[a-z](?:Exception|Error)\b(?!s)/,
    /\bException\b/,
    /\b(?:level|severity|lvl)=["']?(?:error|err|fatal|critical|crit|panic)\b/i
  ].freeze
  WARN_PATTERNS = [
    /\bWARN(?:ING)?\b/,
    /\AW, \[/,
    /\b(?:level|severity|lvl)=["']?(?:warn|warning)\b/i
  ].freeze
  JSON_LEVEL_KEYS = %w[level severity lvl log.level].freeze

  def self.level_for(text)
    json_level = json_level_for(text)
    return json_level unless json_level == :none

    return :error if ERROR_PATTERNS.any? { |pattern| pattern.match?(text) }
    return :warn if WARN_PATTERNS.any? { |pattern| pattern.match?(text) }

    nil
  end

  # :none when the line isn't a JSON object with a level, so the text heuristics get their turn.
  def self.json_level_for(text)
    return :none unless text.start_with?("{") && text.bytesize <= 16.kilobytes

    data = JSON.parse(text)
    return :none unless data.is_a?(Hash)

    value = JSON_LEVEL_KEYS.lazy.map { |key| data[key] }.find { |v| !v.nil? }
    return :none if value.nil?

    case value
    when Integer # pino / bunyan numeric levels
      value >= 50 ? :error : (value >= 40 ? :warn : nil)
    else
      case value.to_s.downcase
      when "error", "err", "fatal", "critical", "crit", "panic", "alert", "emerg", "emergency" then :error
      when "warn", "warning" then :warn
      end
    end
  rescue JSON::ParserError
    :none
  end

  # Follow mode asks again from the newest timestamp it has (docker's --since is inclusive), so the
  # lines at exactly that instant come back a second time; drop the ones it already shows.
  def self.drop_seen(entries, since:, seen_keys:)
    return entries unless since.is_a?(Time)

    seen = seen_keys.to_set
    entries.reject do |entry|
      next false if entry.time.nil?

      entry.time < since || (entry.time == since && seen.include?(entry.key))
    end
  end

  attr_reader :managed_app, :source, :host, :since, :lines, :keyword, :case_sensitive, :seen_keys, :version

  # source: "app" | "app:<role>" | "accessory:<name>" | "proxy"
  # host:   nil/blank for all of the source's hosts, or one of them
  # since:  a WINDOWS key, or an absolute time (Time or ISO 8601 string) no older than MAX_LOOKBACK
  #         ("all" too, but only together with a version)
  # version: blank for the running containers; otherwise one of .versions_for — that version's
  #         containers, stopped ones included (app / role sources only)
  # lines:  one of LINE_LIMITS, per container
  # grep:   fixed string, optional; case-insensitive unless case_sensitive
  # seen:   follow mode's boundary keys (see .drop_seen)
  # ssh / observations: injectable for tests; default to the app's real SSH session and latest
  # observations.
  def initialize(managed_app, source: "app", host: nil, since: DEFAULT_WINDOW, lines: DEFAULT_LINES,
                 grep: nil, case_sensitive: false, seen: [], version: nil, ssh: nil, observations: nil,
                 now: Time.current)
    @managed_app = managed_app
    @now = now
    @observations = observations
    @source = resolve_source(source)
    @host = resolve_host(host)
    @version = resolve_version(version)
    @since = resolve_since(since)
    @lines = resolve_lines(lines)
    @keyword = resolve_keyword(grep)
    @case_sensitive = ActiveModel::Type::Boolean.new.cast(case_sensitive) || false
    @seen_keys = resolve_seen(seen)
    @ssh = ssh
    @marker = "__kp_#{SecureRandom.hex(6)}__"
  end

  # Returns a Result. Never raises for host trouble: each host's failure is a HostError next to the
  # other hosts' lines.
  #
  # Alert rules (spec §8) count keyword hits over the last N minutes across all of an app's hosts:
  #   result = LogQuery.new(app, source: "app", since: N.minutes.ago, grep: "keyword", lines: 1000).call
  #   result.entries.size   # matching lines (at most 1000 per container)
  #   result.errors         # hosts that could not be read; don't treat them as "0 hits"
  def call
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    wall_start = Time.current

    return finish([], [ HostError.new(host: nil, kind: :no_credential, detail: nil) ], [], started, wall_start) if managed_app.ssh_credential.nil?

    targets, errors = resolve_targets
    entries = []
    unless targets.empty?
      prepare_for_threads!
      hosts = targets.keys
      outputs = ParallelMap.call(hosts, threads: MAX_THREADS) { |host| run_on(host, targets[host]) }

      hosts.zip(outputs).each do |host, output|
        if output.is_a?(Exception)
          errors << HostError.new(host: host, kind: :failed, detail: "#{output.class}: #{output.message}")
        elsif output.error
          errors << HostError.new(host: host, kind: :unreachable, detail: output.error)
        else
          host_entries, host_errors = parse_output(host, output.stdout, targets[host])
          entries.concat(host_entries)
          errors.concat(host_errors)
        end
      end
    end

    finish(entries, errors, targets.keys, started, wall_start)
  end

  # The shell command run on one host; containers: [[container_name, label], ...]. Public so tests
  # can check exactly what reaches the shell.
  def command_for(containers)
    containers.each_with_index.map { |(name, _label), index| container_command(name, index) }.join("; ")
  end

  def since_argument
    return nil if since == ALL_TIME

    since.is_a?(Time) ? since.utc.iso8601(9) : since
  end

  private
    attr_reader :marker, :now

    def config = managed_app.parsed_config

    def resolve_source(key)
      key = key.to_s.presence || "app"
      self.class.sources_for(config).find { |source| source.key == key } ||
        raise(InvalidQuery, "unknown source")
    end

    def resolve_host(value)
      return nil if value.blank?
      raise InvalidQuery, "unknown host" unless source.hosts.include?(value.to_s)

      value.to_s
    end

    def resolve_version(value)
      return nil if value.blank?
      raise InvalidQuery, "a version applies to app sources only" unless source.kind.in?(%i[app role])

      version = value.to_s
      known = self.class.versions_for(managed_app, observations).map { |entry| entry[:version] }
      raise InvalidQuery, "unknown version" unless VERSION.match?(version) && known.include?(version)

      version
    end

    def resolve_since(value)
      value = value.presence || DEFAULT_WINDOW
      return value if value.is_a?(String) && WINDOWS.key?(value)
      return ALL_TIME if value == ALL_TIME && version

      time =
        case value
        when Time, ActiveSupport::TimeWithZone then value.to_time
        when String then parse_time(value)
        end
      raise InvalidQuery, "invalid since" if time.nil?
      raise InvalidQuery, "since is too far back" if time < now - MAX_LOOKBACK
      raise InvalidQuery, "since is in the future" if time > now + 5.minutes

      time.utc
    end

    def parse_time(value)
      Time.iso8601(value)
    rescue ArgumentError
      nil
    end

    def resolve_lines(value)
      value = value.presence || DEFAULT_LINES
      number = Integer(value.to_s, 10)
      raise InvalidQuery, "invalid lines" unless LINE_LIMITS.include?(number)

      number
    rescue ArgumentError
      raise InvalidQuery, "invalid lines"
    end

    # A newline would hand grep a second pattern, NUL can't pass through a shell argument.
    def resolve_keyword(value)
      return nil if value.blank?

      keyword = value.to_s
      raise InvalidQuery, "keyword too long" if keyword.length > MAX_KEYWORD_LENGTH
      raise InvalidQuery, "keyword has control characters" if keyword.match?(/[\x00-\x1f\x7f]/)

      keyword
    end

    def resolve_seen(value)
      Array(value).flat_map { |key| key.to_s.split(",") }
                  .select { |key| SEEN_KEY.match?(key) }
                  .first(MAX_SEEN_KEYS)
    end

    def query_hosts = host ? [ host ] : source.hosts

    # { host => [[container, label], ...] } for the hosts worth an SSH round, plus errors for the
    # ones known up front to have nothing to read.
    def resolve_targets
      targets = {}
      errors = []

      query_hosts.each do |query_host|
        containers = containers_on(query_host)
        if containers.empty?
          errors << HostError.new(host: query_host, kind: :no_container, detail: nil)
        else
          targets[query_host] = containers
        end
      end

      [ targets, errors ]
    end

    def containers_on(query_host)
      case source.kind
      when :app, :role then app_containers_on(query_host)
      when :accessory
        name = config.accessory(source.name)&.fetch(:container_name, nil).to_s
        CONTAINER_NAME.match?(name) ? [ [ name, source.name ] ] : []
      when :proxy then [ [ PROXY_CONTAINER, PROXY_CONTAINER ] ]
      end
    end

    # Without a version, only running containers: a host keeps old versions stopped for rollback,
    # and their logs are history, not what is happening now. With one, that version's containers
    # whatever their state — reading that history is the point. The name must carry the role's
    # Kamal prefix either way.
    def app_containers_on(query_host)
      roles = source.kind == :role ? [ source.name ] : config.role_names

      observations.filter_map do |observation|
        next unless observation.host == query_host
        next unless version ? observation.version == version : observation.docker_status == "running"
        next unless roles.include?(observation.role)

        name = observation.container_name.to_s
        prefix = config.container_prefix_for(observation.role)
        next unless prefix && name.start_with?("#{prefix}-") && CONTAINER_NAME.match?(name)

        [ name, observation.role ]
      end.uniq.sort
    end

    def observations
      @observations ||= Observation.latest_for(managed_app).to_a
    end

    # The worker threads must not touch the database: load the credential (and decrypt it) and the
    # parsed config here, on the request thread.
    def prepare_for_threads!
      managed_app.parsed_config
      managed_app.ssh_credential&.value
    end

    def ssh
      @ssh ||= Collectors::SshSession.new(managed_app, execution_timeout: EXECUTION_TIMEOUT)
    end

    def run_on(query_host, containers)
      ssh.capture_many([ query_host ]) { command_for(containers) }.fetch(query_host)
    end

    # Check the container first: `docker logs` on a missing container prints its error into the
    # same stream as the log lines (and grep would swallow it). A marker line, unique to this query,
    # tells the parser which container the following lines belong to.
    def container_command(name, index)
      raise InvalidQuery, "invalid container name" unless CONTAINER_NAME.match?(name)

      container = Shellwords.escape(name)
      begin_marker = Shellwords.escape("#{marker} BEGIN #{index}")
      missing_marker = Shellwords.escape("#{marker} MISSING #{index}")

      readable = version ? "[ \"$s\" = true ] || [ \"$s\" = false ]" : "[ \"$s\" = true ]"
      "s=$(docker container inspect --format '{{.State.Running}}' #{container} 2>&1); " \
        "if #{readable}; then printf '%s\\n' #{begin_marker}; #{logs_pipeline(container)}; " \
        "else printf '%s %s\\n' #{missing_marker} \"$s\"; fi"
    end

    # Without a keyword docker's own --tail reads from the end. With one, the tail must come after
    # grep, or the keyword would only be searched for in the last N lines of the window.
    def logs_pipeline(container)
      base = "docker logs --timestamps"
      base += " --since #{Shellwords.escape(since_argument)}" if since_argument

      if keyword
        flags = case_sensitive ? "-F" : "-F -i"
        "#{base} #{container} 2>&1 | grep #{flags} -e #{Shellwords.escape(keyword)} -- | tail -n #{lines}"
      else
        "#{base} --tail #{lines} #{container} 2>&1"
      end
    end

    def parse_output(query_host, stdout, containers)
      entries = []
      errors = []
      label = nil

      stdout.to_s.dup.force_encoding(Encoding::UTF_8).scrub.each_line(chomp: true) do |raw|
        if raw.start_with?(marker)
          _marker, kind, index, detail = raw.split(" ", 4)
          container, container_label = containers[index.to_i]
          if kind == "BEGIN"
            label = container_label
          else
            label = nil
            errors << missing_container_error(query_host, container, detail.to_s.strip)
          end
          next
        end
        # Anything before the first marker (a login banner) or after a missing container.
        next if label.nil?

        add_line(entries, query_host, label, raw)
      end

      if entries.empty? && errors.empty? && !stdout.to_s.include?(marker)
        errors << HostError.new(host: query_host, kind: :failed, detail: stdout.to_s.strip.truncate(300).presence)
      end

      [ entries, errors ]
    end

    # inspect printed "false": the container exists but is stopped. Anything else is docker's own
    # error (no such container, daemon down), passed on as is.
    def missing_container_error(query_host, container, detail)
      if detail == "false"
        HostError.new(host: query_host, kind: :container_stopped, detail: container)
      else
        HostError.new(host: query_host, kind: :container_missing,
                      detail: [ container, detail.truncate(300).presence ].compact.join(": "))
      end
    end

    # A line without a timestamp continues the previous one (docker splits nothing itself, but a
    # stray CR or a wrapped stack trace can).
    def add_line(entries, query_host, label, raw)
      match = TIMESTAMPED_LINE.match(raw)
      time = match && parse_time(match[1])
      text = clean(time ? match[2] : raw)

      if time.nil? && (previous = entries.last) && previous.source == label
        entries[-1] = previous.with(line: cap("#{previous.line}\n#{text}"),
                                    level: previous.level || self.class.level_for(text))
        return
      end

      return if keyword && !keyword_match?(text)

      entries << Entry.new(time: time&.utc, host: query_host, source: label, line: cap(text),
                           level: self.class.level_for(text))
    end

    def clean(text) = text.gsub(ANSI_ESCAPE, "").delete("\r")

    def cap(text)
      return text if text.bytesize <= MAX_LINE_BYTES

      "#{text.byteslice(0, MAX_LINE_BYTES).scrub('')}…"
    end

    # grep also matched the timestamp prefix; check the text itself so "2026" doesn't match all.
    def keyword_match?(text)
      case_sensitive ? text.include?(keyword) : text.downcase.include?(keyword.downcase)
    end

    def finish(entries, errors, hosts, started, wall_start)
      host_order = hosts.each_with_index.to_h
      entries = entries.each_with_index
                       .sort_by { |entry, index| [ entry.time || Time.at(0), host_order[entry.host] || 0, index ] }
                       .map(&:first)
      entries = self.class.drop_seen(entries, since: since, seen_keys: seen_keys)

      truncated = false
      if entries.size > MAX_ENTRIES
        entries = entries.last(MAX_ENTRIES)
        truncated = true
      end
      bytes = entries.sum { |entry| entry.line.bytesize }
      while bytes > MAX_BYTES && entries.any?
        bytes -= entries.shift.line.bytesize
        truncated = true
      end

      cursor = entries.reverse_each.find(&:time)&.time || (since.is_a?(Time) ? since : wall_start.utc)
      boundary = entries.select { |entry| entry.time == cursor }.map(&:key).last(MAX_SEEN_KEYS)
      # Still at the same instant as last time: keep the lines it already had, too.
      boundary = (seen_keys + boundary).uniq.last(MAX_SEEN_KEYS) if since.is_a?(Time) && cursor == since

      Result.new(entries:, errors:, hosts:, truncated:,
                 duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
                 cursor:, boundary_keys: boundary)
    end
end
