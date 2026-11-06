require "test_helper"

class Metrics::ParsingTest < ActiveSupport::TestCase
  P = Metrics::Parsing

  test "sizes in docker's binary and decimal units, any case, and 0B" do
    assert_equal 0, P.bytes("0B")
    assert_equal 512, P.bytes("512B")
    assert_equal 1_500, P.bytes("1.5kB")
    assert_equal 1_500, P.bytes("1.5KB")
    assert_equal 12_300_000, P.bytes("12.3MB")
    assert_equal 2_000_000_000, P.bytes("2GB")
    assert_equal 1536, P.bytes("1.5KiB")
    assert_equal (12.3 * 1024**2).round, P.bytes("12.3MiB")
    assert_equal (1.94 * 1024**3).round, P.bytes(" 1.94GiB ")
    assert_nil P.bytes("--")
    assert_nil P.bytes("12 parsecs")
    assert_nil P.bytes(nil)
  end

  test "a pair of sizes and percentages" do
    assert_equal [ (12.3 * 1024**2).round, (1.94 * 1024**3).round ], P.byte_pair("12.3MiB / 1.94GiB")
    assert_equal [ 0, 0 ], P.byte_pair("0B / 0B")
    assert_equal [ nil, nil ], P.byte_pair("--")
    assert_in_delta 12.34, P.percent("12.34%")
    assert_nil P.percent("--")
  end

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

  test "/proc/loadavg, /proc/meminfo, df" do
    assert_equal({ load1: 0.52, load5: 0.41, load15: 0.3 }, P.loadavg("0.52 0.41 0.30 1/543 80691\n"))
    assert_equal({}, P.loadavg("garbage"))

    meminfo = "MemTotal:        8022316 kB\nMemAvailable:    6303824 kB\nSwapTotal:       1048572 kB\nSwapFree:              0 kB\n"
    assert_equal({ mem_total_bytes: 8_022_316 * 1024, mem_available_bytes: 6_303_824 * 1024,
                   swap_total_bytes: 1_048_572 * 1024, swap_free_bytes: 0 }, P.meminfo(meminfo))
    assert_equal({}, P.meminfo(""))

    df = "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 41152736 30000000 9000000 77% /\n"
    assert_equal({ disk_total_bytes: 39_000_000 * 1024, disk_used_bytes: 30_000_000 * 1024 }, P.df(df))
    assert_equal({}, P.df("df: /: No such file or directory\n"))
  end

  test "host CPU is the busy share between two /proc/stat readings" do
    first = P.proc_stat("cpu  100 0 100 700 100 0 0 0 0 0\ncpu0 1 2 3\n")
    assert_equal({ cpu_total_jiffies: 1000, cpu_idle_jiffies: 800 }, first)

    second = P.proc_stat("cpu  400 0 200 1200 200 0 0 0 0 0\n")
    # total +1000, idle (idle + iowait) +600 → 40% busy
    assert_in_delta 40.0, P.cpu_percent_between(first, second)

    assert_nil P.cpu_percent_between(nil, second), "first sample"
    assert_nil P.cpu_percent_between(second, first), "counters went backwards: a reboot"
    assert_nil P.cpu_percent_between(second, second), "no time passed"
    assert_equal({}, P.proc_stat("intr 1 2 3"))
  end
end
