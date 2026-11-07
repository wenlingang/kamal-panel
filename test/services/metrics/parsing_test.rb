require "test_helper"

class Metrics::ParsingTest < ActiveSupport::TestCase
  P = Metrics::Parsing

  test "one docker stats JSON line" do
    line = '{"BlockIO":"4.1MB / 0B","CPUPerc":"0.52%","Container":"ab2b","ID":"ab2b","MemPerc":"0.02%",' \
           '"MemUsage":"1.219MiB / 7.651GiB","Name":"blog-web-production-abc","NetIO":"486B / 84B","PIDs":"3"}'
    stats = P.docker_stats_line(line)

    assert_equal "blog-web-production-abc", stats[:name]
    assert_in_delta 0.52, stats[:cpu_percent]
    assert_equal (1.219 * 1024**2).round, stats[:mem_bytes]
    assert_equal (7.651 * 1024**3).round, stats[:mem_limit_bytes]
    assert_in_delta 0.02, stats[:mem_percent]
    assert_equal [ 486, 84 ], stats.values_at(:net_rx_bytes, :net_tx_bytes)
    assert_equal [ 4_100_000, 0 ], stats.values_at(:block_read_bytes, :block_write_bytes)
    assert_equal 3, stats[:pids]

    assert_nil P.docker_stats_line("Cannot connect to the Docker daemon at unix:///var/run/docker.sock.")
    assert_nil P.docker_stats_line('{"no":"name"}')
    assert_nil P.docker_stats_line("[1,2]")
  end
end
