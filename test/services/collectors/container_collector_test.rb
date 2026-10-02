require "test_helper"
require "shellwords"

class Collectors::ContainerCollectorTest < ExecutionLayerTest
  def build_app(hosts:)
    yaml = <<~YAML
      service: blog
      image: example/blog
      servers:
        web:
      #{hosts.map { |h| "      - #{h}" }.join("\n")}
      registry:
        server: registry.example.com
        username: someone
        password:
          - KAMAL_REGISTRY_PASSWORD
      builder:
        arch: amd64
      ssh:
        user: deploy
        port: #{FakeHost::NODES.fetch("node-1")}
    YAML

    app_name = "blog-#{SecureRandom.hex(4)}"
    ManagedApp.create!(
      name: app_name, config_yaml: yaml, destination: "production",
      ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key,
                                      name: "#{app_name} 的 SSH 私钥")
    )
  end

  test "collects running containers and parses their version and role" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")

    app = build_app(hosts: [ "127.0.0.1" ])
    Collectors::ContainerCollector.call(app)

    observation = Observation.latest_for(app).first

    assert_equal "aaaaaaa", observation.version
    assert_equal "web", observation.role
    assert_equal "blog-web-production-aaaaaaa", observation.container_name
    assert_equal "running", observation.docker_status
    assert observation.reachable
  end

  test "also collects stopped old-version containers, which are the rollback candidates" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "0000000",
                            state: :stopped)

    app = build_app(hosts: [ "127.0.0.1" ])
    Collectors::ContainerCollector.call(app)

    by_version = Observation.latest_for(app).index_by(&:version)

    assert_equal "running", by_version["aaaaaaa"].docker_status
    assert_equal "exited",  by_version["0000000"].docker_status
  end

  test "collects only this app's containers without leaking in other services" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")
    FakeHost.seed_container(node: "node-1", service: "shop", role: "web",
                            destination: "production", version: "bbbbbbb")

    app = build_app(hosts: [ "127.0.0.1" ])
    Collectors::ContainerCollector.call(app)

    versions = Observation.latest_for(app).pluck(:version)

    assert_equal [ "aaaaaaa" ], versions
  end

  test "writes an unreachable record when the host cannot be reached instead of writing nothing" do
    app = build_app(hosts: [ "192.0.2.1" ])
    Collectors::ContainerCollector.call(app)

    observation = Observation.latest_for(app).first

    refute observation.reachable
    assert_predicate observation.error, :present?
  end

  test "still leaves a trace when the host is reachable but has no containers" do
    app = build_app(hosts: [ "127.0.0.1" ])
    Collectors::ContainerCollector.call(app)

    observation = Observation.latest_for(app).first

    assert observation.reachable
    assert_nil observation.container_name
    assert_nil observation.docker_status
    assert_nil observation.version
  end

  # A real scenario found in review: docker ps's `.Labels` field flattens all of a container's
  # labels into one comma-joined "k=v,k=v,..." string. The old implementation naively split this
  # string on "," and then on "=" -- even if role/destination themselves have no commas, as long as
  # the container also carries *other* labels whose values contain commas (accessory, compose,
  # health check groups... these can all look like this), the old implementation would split that
  # label into a fragment with no "=", the whole parse_labels would raise, get swallowed by rescue,
  # and degrade to an empty hash -- role becomes nil, the version prefix is computed without
  # role/destination, silently producing a wrong version. That is worse than crashing: the panel
  # would show the wrong role/version at the scene of an incident instead of reporting an error. The
  # new implementation uses docker's own `.Label` function to JSON-encode each field's value
  # separately, no longer relying on splitting this flattened string, so it is naturally immune to
  # "some unrelated label contains a comma".
  test "commas in other label values do not corrupt role/version parsing" do
    name = "blog-web-production-aaaaaaa"

    FakeHost.ssh("node-1", <<~SH)
      docker run -d --name #{Shellwords.escape(name)} \
        --label service=blog \
        --label destination=production \
        --label role=web \
        --label kamal.deploy_group=#{Shellwords.escape('frontend,canary')} \
        busybox:latest sleep 3600
    SH

    app = build_app(hosts: [ "127.0.0.1" ])
    Collectors::ContainerCollector.call(app)

    observation = Observation.latest_for(app).first

    assert_equal "web", observation.role
    assert_equal "aaaaaaa", observation.version
    assert_equal "running", observation.docker_status
  end

  test "skips an unparseable docker ps line and logs it instead of silently dropping it" do
    app = build_app(hosts: [ "127.0.0.1" ])

    fake_session = Object.new
    fake_session.define_singleton_method(:capture_many) do |hosts|
      hosts.index_with { |h| Collectors::SshSession::Result.new(host: h, stdout: "not-json\n", error: nil) }
    end

    original_new = Collectors::SshSession.method(:new)
    Collectors::SshSession.define_singleton_method(:new) { |*_args| fake_session }

    log_output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = Logger.new(log_output)

    count = Collectors::ContainerCollector.call(app)

    # If every row fails to parse, it must leave a row of trace rather than zero rows -- zero rows
    # would let the previous round's stale observations keep being rendered as the current state
    # under the identity of "latest" (see final review I1).
    assert_equal 1, count

    observation = Observation.latest_for(app).first
    refute observation.reachable, "an unparseable line must not be silently counted as \"reachable and healthy\""
    assert_match(/无法解析/, observation.error)
    refute_match(/not-json/, observation.error.to_s,
      "the persisted error summary must not contain the raw line content")

    logged = log_output.string
    assert_match(/无法解析 docker ps 输出/, logged)
    assert_match(/JSON::ParserError/, logged)
    assert_match(/127\.0\.0\.1/, logged)
    refute_match(/not-json/, logged, "the raw line content (or any error excerpt derived from it) must not be logged")
  ensure
    Collectors::SshSession.define_singleton_method(:new, original_new)
    Rails.logger = original_logger
  end
end
