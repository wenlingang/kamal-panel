require "test_helper"

# LogQuery without SSH: a fake session records the commands and answers with canned docker output.
# The real round trip against the fake hosts is in log_query_integration_test.rb.
class LogQueryTest < ActiveSupport::TestCase
  CONFIG = <<~YAML.freeze
    service: blog
    image: example/blog
    servers:
      web:
        - 10.0.0.1
        - 10.0.0.2
      worker:
        hosts:
          - 10.0.0.2
        cmd: bin/jobs
    registry:
      server: registry.example.com
      username: someone
      password:
        - KAMAL_REGISTRY_PASSWORD
    builder:
      arch: amd64
    ssh:
      user: deploy
    accessories:
      db:
        image: postgres:16
        host: 10.0.0.3
  YAML

  # Answers each host with what the block returns for (host, marker, command); records commands.
  class FakeSsh
    attr_reader :commands

    def initialize(&responder)
      @responder = responder
      @commands = {}
      @lock = Mutex.new
    end

    def capture_many(hosts)
      hosts.to_h do |host|
        command = yield(host)
        @lock.synchronize { @commands[host] = command }
        marker = command[/__kp_\h+__/]
        stdout, error = @responder.call(host, marker, command)
        [ host, Collectors::SshSession::Result.new(host: host, stdout: stdout, error: error) ]
      end
    end
  end

  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: CONFIG, destination: "production",
                              ssh_credential: Credential.create!(kind: "ssh_key", name: "key",
                                                                 value: FakeHost.private_key))
    @observations = [
      observation("10.0.0.1", "web", "blog-web-production-aaa", "running"),
      observation("10.0.0.1", "web", "blog-web-production-old", "exited"),
      observation("10.0.0.2", "web", "blog-web-production-aaa", "running"),
      observation("10.0.0.2", "worker", "blog-worker-production-aaa", "running")
    ]
  end

  def observation(host, role, name, status)
    Observation.new(managed_app: @app, host: host, role: role, container_name: name, docker_status: status,
                    version: name.split("-").last, reachable: true, observed_at: Time.current)
  end

  def query(ssh: FakeSsh.new { |_h, marker, _c| [ "#{marker} BEGIN 0\n", nil ] }, **options)
    LogQuery.new(@app, ssh: ssh, observations: @observations, **options)
  end

  # --- input whitelisting -------------------------------------------------------------------------

  test "accepts the documented values" do
    q = query(source: "app:worker", host: "10.0.0.2", since: "1h", lines: "500", grep: "boom")

    assert_equal "app:worker", q.source.key
    assert_equal "10.0.0.2", q.host
    assert_equal "1h", q.since
    assert_equal 500, q.lines
    assert_equal "boom", q.keyword
  end

  test "rejects anything outside the whitelists" do
    [
      { source: "accessory:nope" }, { source: "app; rm -rf /" }, { source: "app:nope" },
      { host: "10.9.9.9" }, { source: "accessory:db", host: "10.0.0.1" },
      { since: "2d" }, { since: "15m; reboot" }, { since: 48.hours.ago.iso8601 }, { since: 1.hour.from_now.iso8601 },
      { lines: "100" }, { lines: "200; id" }, { lines: "abc" },
      { grep: "x" * 201 }, { grep: "a\nb" }, { grep: "a\u0000b" }
    ].each do |options|
      assert_raises(LogQuery::InvalidQuery, "should reject #{options.inspect}") { query(**options) }
    end
  end

  test "blank values fall back to the defaults" do
    q = query(source: "", host: "", since: "", lines: "", grep: "")

    assert_equal "app", q.source.key
    assert_nil q.host
    assert_equal "15m", q.since
    assert_equal 200, q.lines
    assert_nil q.keyword
  end

  test "an absolute since within a day is passed to docker as RFC3339Nano UTC" do
    time = Time.utc(2026, 11, 5, 8, 0, 0, Rational(123_456_789, 1000))
    q = query(since: time.iso8601(9), now: time + 10.minutes)

    assert_equal "2026-11-05T08:00:00.123456789Z", q.since_argument
  end

  test "the sources an app offers" do
    keys = LogQuery.sources_for(@app.parsed_config).map(&:key)

    assert_equal %w[app app:web app:worker accessory:db proxy], keys
  end

  # --- command building ---------------------------------------------------------------------------

  test "builds a docker logs command per running container, without --tail after grep" do
    ssh = FakeSsh.new { |_h, marker, _c| [ "#{marker} BEGIN 0\n", nil ] }
    query(ssh: ssh, since: "5m", lines: 500).call

    command = ssh.commands.fetch("10.0.0.1")
    assert_includes command, "docker container inspect --format '{{.State.Running}}' blog-web-production-aaa"
    assert_includes command, "docker logs --timestamps --since 5m --tail 500 blog-web-production-aaa 2>&1"
    assert_not_includes command, "blog-web-production-old", "stopped containers must not be read"
    assert_includes ssh.commands.fetch("10.0.0.2"), "blog-worker-production-aaa"
  end

  test "a keyword goes to grep -F after -e and before --, escaped, and the tail comes after grep" do
    ssh = FakeSsh.new { |_h, marker, _c| [ "#{marker} BEGIN 0\n", nil ] }
    query(ssh: ssh, host: "10.0.0.1", grep: "'; rm -rf / #").call

    command = ssh.commands.fetch("10.0.0.1")
    escaped = Shellwords.escape("'; rm -rf / #")
    assert_includes command, "| grep -F -i -e #{escaped} -- | tail -n 200"
    assert_not_includes command, "--tail"
    # What the shell actually receives as grep's arguments: the keyword as one word.
    pipeline = command[/grep .*? -- /]
    assert_equal [ "grep", "-F", "-i", "-e", "'; rm -rf / #", "--" ], Shellwords.split(pipeline)
  end

  test "a keyword that looks like an option stays a pattern" do
    ssh = FakeSsh.new { |_h, marker, _c| [ "#{marker} BEGIN 0\n", nil ] }
    query(ssh: ssh, host: "10.0.0.1", grep: "-e --help $(id) `id`", case_sensitive: "1").call

    pipeline = ssh.commands.fetch("10.0.0.1")[/grep .*? -- /]
    assert_equal [ "grep", "-F", "-e", "-e --help $(id) `id`", "--" ], Shellwords.split(pipeline)
  end

  test "accessory and proxy sources read their fixed container names" do
    ssh = FakeSsh.new { |_h, marker, _c| [ "#{marker} BEGIN 0\n", nil ] }
    query(ssh: ssh, source: "accessory:db").call
    assert_equal [ "10.0.0.3" ], ssh.commands.keys
    assert_includes ssh.commands["10.0.0.3"], "docker logs --timestamps --since 15m --tail 200 blog-db 2>&1"

    ssh = FakeSsh.new { |_h, marker, _c| [ "#{marker} BEGIN 0\n", nil ] }
    query(ssh: ssh, source: "proxy").call
    assert_equal %w[10.0.0.1 10.0.0.2], ssh.commands.keys.sort
    assert_includes ssh.commands["10.0.0.1"], " kamal-proxy 2>&1"
  end

  test "container names that aren't docker names never reach the shell" do
    @observations = [ observation("10.0.0.1", "web", "blog-web-production-$(reboot)", "running") ]
    ssh = FakeSsh.new { |_h, marker, _c| [ "#{marker} BEGIN 0\n", nil ] }

    result = query(ssh: ssh, host: "10.0.0.1").call

    assert_empty ssh.commands
    assert_equal [ :no_container ], result.errors.map(&:kind)
  end

  test "containers of another service are ignored even if observed" do
    @observations = [ observation("10.0.0.1", "web", "other-web-production-aaa", "running") ]
    result = query(host: "10.0.0.1").call

    assert_equal [ :no_container ], result.errors.map(&:kind)
  end

  # --- parsing, merging, sorting ------------------------------------------------------------------

  test "merges hosts into one timeline sorted by timestamp, tagged with host and role" do
    ssh = FakeSsh.new do |host, marker, _command|
      case host
      when "10.0.0.1"
        [ "#{marker} BEGIN 0\n2026-11-05T08:00:01.000000002Z web one b\n2026-11-05T08:00:03.5Z web one d\n", nil ]
      when "10.0.0.2"
        [ "#{marker} BEGIN 0\n2026-11-05T08:00:02Z web two c\n#{marker} BEGIN 1\n" \
          "2026-11-05T08:00:01.000000001Z worker a\n", nil ]
      end
    end

    result = query(ssh: ssh).call

    assert_equal [ "worker a", "web one b", "web two c", "web one d" ], result.entries.map(&:line)
    assert_equal %w[10.0.0.2 10.0.0.1 10.0.0.2 10.0.0.1], result.entries.map(&:host)
    assert_equal %w[worker web web web], result.entries.map(&:source)
    assert_equal Time.utc(2026, 11, 5, 8, 0, 3.5), result.cursor
    assert_equal 2, result.host_count
    assert_empty result.errors
  end

  test "a line without a timestamp continues the previous one" do
    ssh = FakeSsh.new do |_host, marker, _command|
      [ "#{marker} BEGIN 0\n2026-11-05T08:00:01Z RuntimeError: boom\n  from app.rb:1\n2026-11-05T08:00:02Z ok\n", nil ]
    end

    result = query(ssh: ssh, host: "10.0.0.1").call

    assert_equal [ "RuntimeError: boom\n  from app.rb:1", "ok" ], result.entries.map(&:line)
    assert_equal :error, result.entries.first.level
  end

  test "strips ANSI colours and scrubs invalid UTF-8" do
    ssh = FakeSsh.new do |_host, marker, _command|
      [ "#{marker} BEGIN 0\n2026-11-05T08:00:01Z \e[31mred\e[0m \xFF\n".b, nil ]
    end

    line = query(ssh: ssh, host: "10.0.0.1").call.entries.first.line

    assert_equal "red �", line
  end

  test "drops grep hits that only matched the timestamp" do
    ssh = FakeSsh.new do |_host, marker, _command|
      [ "#{marker} BEGIN 0\n2026-11-05T08:00:01Z nothing here\n2026-11-05T08:00:02Z the 2026 report\n", nil ]
    end

    result = query(ssh: ssh, host: "10.0.0.1", grep: "2026").call

    assert_equal [ "the 2026 report" ], result.entries.map(&:line)
  end

  test "caps the number of entries, keeping the newest" do
    body = Array.new(LogQuery::MAX_ENTRIES + 10) { |i| "2026-11-05T08:00:00.#{format('%09d', i)}Z line #{i}" }.join("\n")
    ssh = FakeSsh.new { |_host, marker, _command| [ "#{marker} BEGIN 0\n#{body}\n", nil ] }

    result = query(ssh: ssh, host: "10.0.0.1").call

    assert result.truncated
    assert_equal LogQuery::MAX_ENTRIES, result.entries.size
    assert_equal "line #{LogQuery::MAX_ENTRIES + 9}", result.entries.last.line
    assert_equal "line 10", result.entries.first.line
  end

  # --- per-host errors ----------------------------------------------------------------------------

  test "maps per-host failures to errors without losing the other hosts" do
    @observations << observation("10.0.0.1", "worker", "blog-worker-production-aaa", "running")
    ssh = FakeSsh.new do |host, marker, _command|
      case host
      when "10.0.0.1" then [ nil, "Errno::EHOSTUNREACH: No route to host" ]
      when "10.0.0.2"
        [ "#{marker} MISSING 0 Error: No such object: blog-web-production-aaa\n#{marker} MISSING 1 false\n", nil ]
      end
    end

    result = query(ssh: ssh).call

    by_host = result.errors.group_by(&:host)
    assert_equal [ :unreachable ], by_host["10.0.0.1"].map(&:kind)
    assert_equal %i[container_missing container_stopped], by_host["10.0.0.2"].map(&:kind)
    assert_includes by_host["10.0.0.2"].first.detail, "No such object"
    assert_empty result.entries
  end

  test "a host with no running container is reported without an SSH round" do
    @observations = @observations.reject { |o| o.host == "10.0.0.1" }
    ssh = FakeSsh.new { |_h, marker, _c| [ "#{marker} BEGIN 0\n", nil ] }

    result = query(ssh: ssh, source: "app:web").call

    assert_equal [ "10.0.0.2" ], ssh.commands.keys
    assert_equal [ [ "10.0.0.1", :no_container ] ], result.errors.map { |e| [ e.host, e.kind ] }
  end

  test "output without any marker is a failure, not an empty result" do
    ssh = FakeSsh.new { |_h, _marker, _c| [ "sh: docker: not found\n", nil ] }

    result = query(ssh: ssh, host: "10.0.0.1").call

    assert_equal [ :failed ], result.errors.map(&:kind)
    assert_includes result.errors.first.detail, "docker: not found"
  end

  test "an app without an SSH key reports that once and connects nowhere" do
    @app.update_columns(ssh_credential_id: nil)
    @app.reload
    ssh = FakeSsh.new { |_h, marker, _c| [ "#{marker} BEGIN 0\n", nil ] }

    result = query(ssh: ssh).call

    assert_empty ssh.commands
    assert_equal [ [ nil, :no_credential ] ], result.errors.map { |e| [ e.host, e.kind ] }
  end

  # --- level detection ----------------------------------------------------------------------------

  test "detects levels from common log formats" do
    {
      "E, [2026-11-05T08:00:00 #1] ERROR -- : boom" => :error,
      "F, [2026-11-05T08:00:00 #1] FATAL -- : boom" => :error,
      "W, [2026-11-05T08:00:00 #1]  WARN -- : slow" => :warn,
      "I, [2026-11-05T08:00:00 #1]  INFO -- : ok" => nil,
      "NoMethodError: undefined method" => :error,
      "java.lang.IllegalStateException at Foo" => :error,
      "time=1 level=error msg=x" => :error,
      "level=warn msg=x" => :warn,
      "WARNING: disk almost full" => :warn,
      "0 errors, 2 warnings" => nil,
      '{"level":"error","msg":"x"}' => :error,
      '{"severity":"WARNING"}' => :warn,
      '{"level":50,"msg":"pino"}' => :error,
      '{"level":30,"msg":"ERROR in text but info level"}' => nil,
      '{"msg":"no level, but ERROR"}' => :error,
      "{not json ERROR" => :error
    }.each do |line, level|
      if level.nil?
        assert_nil LogQuery.level_for(line), line
      else
        assert_equal level, LogQuery.level_for(line), line
      end
    end
  end

  # --- follow mode boundary -----------------------------------------------------------------------

  test "drop_seen removes older lines and the already shown lines at the boundary" do
    since = Time.utc(2026, 11, 5, 8, 0, 1)
    shown = LogQuery::Entry.new(time: since, host: "h", source: "web", line: "shown", level: nil)
    same_instant = LogQuery::Entry.new(time: since, host: "h", source: "web", line: "new at same instant", level: nil)
    older = LogQuery::Entry.new(time: since - 1, host: "h", source: "web", line: "older", level: nil)
    newer = LogQuery::Entry.new(time: since + 1, host: "h", source: "web", line: "newer", level: nil)

    kept = LogQuery.drop_seen([ older, shown, same_instant, newer ], since: since, seen_keys: [ shown.key ])

    assert_equal [ "new at same instant", "newer" ], kept.map(&:line)
  end

  test "a follow query drops the boundary lines it was told about and hands out the next cursor" do
    ssh = FakeSsh.new do |_host, marker, _command|
      [ "#{marker} BEGIN 0\n2026-11-05T08:00:01Z shown\n2026-11-05T08:00:02Z new\n", nil ]
    end
    since = Time.utc(2026, 11, 5, 8, 0, 1)
    shown_key = LogQuery::Entry.new(time: since, host: "10.0.0.1", source: "web", line: "shown", level: nil).key

    result = query(ssh: ssh, host: "10.0.0.1", since: since.iso8601(9), seen: shown_key, now: since + 1.minute).call

    assert_equal [ "new" ], result.entries.map(&:line)
    assert_equal since + 1, result.cursor
    assert_equal [ result.entries.last.key ], result.boundary_keys
  end

  test "with nothing new the cursor stays and the seen keys carry over" do
    ssh = FakeSsh.new { |_host, marker, _command| [ "#{marker} BEGIN 0\n2026-11-05T08:00:01Z shown\n", nil ] }
    since = Time.utc(2026, 11, 5, 8, 0, 1)
    shown_key = LogQuery::Entry.new(time: since, host: "10.0.0.1", source: "web", line: "shown", level: nil).key

    result = query(ssh: ssh, host: "10.0.0.1", since: since.iso8601(9), seen: [ shown_key, "not-a-key" ],
                   now: since + 1.minute).call

    assert_empty result.entries
    assert_equal since, result.cursor
    assert_equal [ shown_key ], result.boundary_keys
  end
  # --- old versions --------------------------------------------------------------------------------

  test "versions_for lists the versions the hosts still have, running ones first" do
    assert_equal [ { version: "aaa", running: true }, { version: "old", running: false } ],
                 LogQuery.versions_for(@app, @observations)
  end

  test "with a version, that version's containers are read even when stopped, and only those" do
    ssh = FakeSsh.new { |_h, marker, _c| [ "#{marker} BEGIN 0\n2026-11-06T01:00:00.000000000Z bye\n", nil ] }
    result = query(ssh:, version: "old", since: "all").call

    assert_equal [ "10.0.0.1" ], ssh.commands.keys, "only the host that still has the old container"
    command = ssh.commands["10.0.0.1"]
    assert_includes command, "blog-web-production-old"
    assert_not_includes command, "blog-web-production-aaa"
    assert_includes command, '[ "$s" = false ]', "a stopped container is readable in version mode"
    assert_not_includes command, "--since", "all time: no --since at all"
    assert_includes command, "--tail 200"
    assert_equal [ "bye" ], result.entries.map(&:line)
  end

  test "without a version a stopped container is still not readable" do
    ssh = FakeSsh.new { |_h, marker, _c| [ "#{marker} BEGIN 0\n", nil ] }
    query(ssh:).call

    assert ssh.commands.values.none? { |command| command.include?('"$s" = false') }
    assert ssh.commands.values.none? { |command| command.include?("blog-web-production-old") }
  end

  test "version input is whitelisted" do
    assert_raises(LogQuery::InvalidQuery) { query(version: "nope") }
    assert_raises(LogQuery::InvalidQuery) { query(version: "-e x") }
    assert_raises(LogQuery::InvalidQuery) { query(source: "accessory:db", version: "old") }
    assert_raises(LogQuery::InvalidQuery, "all time only goes with a version") { query(since: "all") }
    assert_equal "old", query(source: "app:web", version: "old").version
  end
end
