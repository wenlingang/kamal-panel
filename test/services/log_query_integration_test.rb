require "test_helper"

# LogQuery against a real docker daemon over real SSH (the fake hosts): the command it builds must
# actually run in the remote shell, docker's timestamps must parse, and grep must filter remotely.
class LogQueryIntegrationTest < ExecutionLayerTest
  CONTAINER_SCRIPT = "echo 'I, [x] INFO -- : booted'; echo 'E, [x] ERROR -- : Boom happened'; " \
                     "echo \"it's a quote; \\$(id)\"; sleep 3600"

  setup do
    @app = ManagedApp.create!(
      name: "blog-#{SecureRandom.hex(4)}", config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production",
      ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key, name: "logs-#{SecureRandom.hex(4)}")
    )
    @container = FakeHost.seed_container(node: "node-1", service: "blog", role: "web", destination: "production",
                                         version: "aaaaaaa", command: CONTAINER_SCRIPT)
    # Give the container a moment to print before docker logs reads it.
    sleep 1
    Observation.create!(managed_app: @app, host: "127.0.0.1", role: "web", container_name: @container,
                        docker_status: "running", version: "aaaaaaa", reachable: true, observed_at: Time.current)
  end

  test "reads a running container's lines with their timestamps and levels" do
    result = LogQuery.new(@app, source: "app:web").call

    assert_empty result.errors
    assert_equal [ "I, [x] INFO -- : booted", "E, [x] ERROR -- : Boom happened", "it's a quote; $(id)" ],
                 result.entries.map(&:line)
    assert_equal [ nil, :error, nil ], result.entries.map(&:level)
    assert result.entries.all? { |entry| entry.time.is_a?(Time) && entry.time > 1.hour.ago }
    assert_equal [ "web" ], result.entries.map(&:source).uniq
  end

  test "filters with a keyword on the host, case-insensitive by default, quotes and all" do
    assert_equal [ "E, [x] ERROR -- : Boom happened" ],
                 LogQuery.new(@app, source: "app:web", grep: "boom").call.entries.map(&:line)
    assert_empty LogQuery.new(@app, source: "app:web", grep: "boom", case_sensitive: true).call.entries
    assert_equal [ "it's a quote; $(id)" ],
                 LogQuery.new(@app, source: "app:web", grep: "'s a quote; $(id)").call.entries.map(&:line)
    assert_empty LogQuery.new(@app, source: "app:web", grep: "-v").call.entries
  end

  test "follow mode from the newest timestamp returns nothing new" do
    first = LogQuery.new(@app, source: "app:web").call
    again = LogQuery.new(@app, source: "app:web", since: first.cursor, seen: first.boundary_keys).call

    assert_empty again.errors
    assert_empty again.entries
  end

  test "a container that is gone and a stopped one are reported per host" do
    FakeHost.ssh("node-1", "docker stop -t 0 #{Shellwords.escape(@container)}")
    assert_equal [ :container_stopped ], LogQuery.new(@app, source: "app:web").call.errors.map(&:kind)

    FakeHost.ssh("node-1", "docker rm -f #{Shellwords.escape(@container)}")
    errors = LogQuery.new(@app, source: "app:web").call.errors
    assert_equal [ :container_missing ], errors.map(&:kind)
    assert_includes errors.first.detail, @container
  end
end
