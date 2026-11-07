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

  # --- command building ---------------------------------------------------------------------------

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

  test "container names that aren't docker names never reach the shell" do
    @observations = [ observation("10.0.0.1", "web", "blog-web-production-$(reboot)", "running") ]
    ssh = FakeSsh.new { |_h, marker, _c| [ "#{marker} BEGIN 0\n", nil ] }

    result = query(ssh: ssh, host: "10.0.0.1").call

    assert_empty ssh.commands
    assert_equal [ :no_container ], result.errors.map(&:kind)
  end

  # --- parsing, merging, sorting ------------------------------------------------------------------

  # --- per-host errors ----------------------------------------------------------------------------

  # --- level detection ----------------------------------------------------------------------------

  # --- follow mode boundary -----------------------------------------------------------------------

  # --- old versions --------------------------------------------------------------------------------
end
