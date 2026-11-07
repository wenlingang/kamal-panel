require "test_helper"

class Collectors::MetricsCollectorTest < ActiveSupport::TestCase
  # Answers capture_many like SshSession, from canned output per host.
  class StubSsh
    attr_reader :commands

    def initialize(outputs)
      @outputs = outputs
      @commands = []
    end

    def capture_many(hosts)
      hosts.index_with do |host|
        @commands << yield(host)
        output = @outputs.fetch(host) { { error: "Errno::EHOSTUNREACH: unreachable" } }
        Collectors::SshSession::Result.new(host:, stdout: output[:stdout], error: output[:error])
      end
    end
  end

  setup do
    @app = ManagedApp.create!(name: "blog", destination: "production", config_yaml: <<~YAML)
      service: blog
      image: example/blog
      servers:
        web:
          - 10.0.0.1
          - 10.0.0.2
        worker:
          hosts:
            - 10.0.0.1
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
    @now = Time.zone.parse("2026-11-05 10:00:30")
  end

  def stats(name, cpu: "1.50%", mem: "100MiB / 7.651GiB", mem_perc: "1.28%")
    { "Name" => name, "CPUPerc" => cpu, "MemUsage" => mem, "MemPerc" => mem_perc,
      "NetIO" => "1.2kB / 3.4MB", "BlockIO" => "0B / 8.19kB", "PIDs" => "7" }.to_json
  end

  def output(stats_lines, stat: "cpu  100 0 100 700 100 0 0 0 0 0")
    marker = Collectors::MetricsCollector::MARKER
    <<~OUT
      #{marker}stats
      #{stats_lines.join("\n")}
      #{marker}loadavg
      0.52 0.41 0.30 1/543 80691
      #{marker}nproc
      4
      #{marker}meminfo
      MemTotal:        8022316 kB
      MemAvailable:    6303824 kB
      SwapTotal:             0 kB
      SwapFree:              0 kB
      #{marker}stat
      #{stat}
      #{marker}df
      Filesystem 1024-blocks Used Available Capacity Mounted on
      overlay 474095688 9317440 440622040 3% /
    OUT
  end

  def collect(now: @now, **outputs)
    ssh = StubSsh.new(outputs)
    Collectors::MetricsCollector.call(@app, now:, ssh:)
    ssh
  end

  test "keeps this app's containers, accessories and the proxy; skips everyone else's" do
    collect("10.0.0.1" => { stdout: output([ stats("blog-web-production-abc1234"),
                                              stats("blog-worker-production-abc1234", mem: "300MiB / 512MiB", mem_perc: "58.6%"),
                                              stats("kamal-proxy"),
                                              stats("shop-web-production-fff0000") ]) },
            "10.0.0.3" => { stdout: output([ stats("blog-db") ]) })

    rows = ContainerMetric.where(managed_app: @app).order(:host, :container_name).map do |m|
      [ m.host, m.kind, m.source, m.version ]
    end
    assert_equal [ [ "10.0.0.1", "app", "web", "abc1234" ], [ "10.0.0.1", "app", "worker", "abc1234" ],
                   [ "10.0.0.1", "proxy", "kamal-proxy", nil ], [ "10.0.0.3", "accessory", "db", nil ] ].sort,
                 rows.sort

    web = ContainerMetric.find_by!(source: "web")
    assert_in_delta 1.5, web.cpu_percent
    assert_equal 100 * 1024**2, web.mem_bytes
    assert_nil web.mem_limit_bytes, "docker reports the host's memory when there is no limit"
    assert_equal [ 1200, 3_400_000, 0, 8190, 7 ], [ web.net_rx_bytes, web.net_tx_bytes, web.block_read_bytes, web.block_write_bytes, web.pids ]
    assert_equal @now.change(sec: 0), web.sampled_at
    assert_equal 512 * 1024**2, ContainerMetric.find_by!(source: "worker").mem_limit_bytes
  end
end
