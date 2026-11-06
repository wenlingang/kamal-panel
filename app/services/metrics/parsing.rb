require "json"

module Metrics
  # Turns the text one metrics SSH round prints into numbers. Pure functions, no database, so the
  # odd formats (docker's two unit systems, a missing /proc file) are tested without a host.
  module Parsing
    # docker stats prints memory in binary units (go-units BytesSize: "12.3MiB / 1.94GiB") and
    # network / block IO in decimal ones (HumanSize: "1.2kB / 3.4MB"). Both appear, sometimes in
    # upper case, so every spelling maps here.
    UNITS = {
      "b" => 1,
      "kb" => 1_000, "mb" => 1_000**2, "gb" => 1_000**3, "tb" => 1_000**4, "pb" => 1_000**5,
      "kib" => 1024, "mib" => 1024**2, "gib" => 1024**3, "tib" => 1024**4, "pib" => 1024**5
    }.freeze

    SIZE = /\A\s*(\d+(?:\.\d+)?)\s*([a-z]*)\s*\z/i

    module_function

    # "12.3MiB" → 12897484; "0B" → 0; "--" / garbage → nil.
    def bytes(text)
      match = SIZE.match(text.to_s)
      return nil unless match

      factor = UNITS[match[2].downcase.presence || "b"]
      return nil unless factor

      (match[1].to_f * factor).round
    end

    # "12.3MiB / 1.94GiB" → [12897484, 2083059138]
    def byte_pair(text)
      left, right = text.to_s.split("/", 2)
      [ bytes(left), bytes(right) ]
    end

    # "12.34%" → 12.34; "--" → nil.
    def percent(text)
      value = text.to_s.strip.delete_suffix("%")
      Float(value, exception: false)
    end

    def integer(text)
      Integer(text.to_s.strip, 10, exception: false)
    end

    # One line of `docker stats --format '{{json .}}'`; nil for a line that isn't such JSON.
    def docker_stats_line(line)
      data = JSON.parse(line)
      return nil unless data.is_a?(Hash) && data["Name"].present?

      mem_bytes, mem_limit = byte_pair(data["MemUsage"])
      net_rx, net_tx = byte_pair(data["NetIO"])
      block_read, block_write = byte_pair(data["BlockIO"])

      { name: data["Name"].to_s, cpu_percent: percent(data["CPUPerc"]),
        mem_bytes: mem_bytes, mem_limit_bytes: mem_limit, mem_percent: percent(data["MemPerc"]),
        net_rx_bytes: net_rx, net_tx_bytes: net_tx,
        block_read_bytes: block_read, block_write_bytes: block_write,
        pids: integer(data["PIDs"]) }
    rescue JSON::ParserError
      nil
    end

    # "0.52 0.41 0.30 1/543 80691" → { load1: 0.52, load5: 0.41, load15: 0.30 }
    def loadavg(text)
      values = text.to_s.split.first(3).map { |value| Float(value, exception: false) }
      return {} unless values.size == 3 && values.all?

      { load1: values[0], load5: values[1], load15: values[2] }
    end

    # The lines of /proc/meminfo (values in kB) → bytes.
    MEMINFO_KEYS = { "MemTotal" => :mem_total_bytes, "MemAvailable" => :mem_available_bytes,
                     "SwapTotal" => :swap_total_bytes, "SwapFree" => :swap_free_bytes }.freeze

    def meminfo(text)
      text.to_s.lines.each_with_object({}) do |line, result|
        key, value = line.split(":", 2)
        attribute = MEMINFO_KEYS[key.to_s.strip]
        kilobytes = value.to_s[/\d+/]
        result[attribute] = kilobytes.to_i * 1024 if attribute && kilobytes
      end
    end

    # The aggregate "cpu" line of /proc/stat:
    #   cpu user nice system idle iowait irq softirq steal guest guest_nice
    # guest / guest_nice are already counted in user / nice, so the total is the first eight.
    # Idle time includes iowait: a CPU waiting on disk is not busy.
    def proc_stat(text)
      line = text.to_s.lines.find { |l| l.start_with?("cpu ") }
      return {} unless line

      fields = line.split.drop(1).first(8).map { |value| Integer(value, 10, exception: false) }
      return {} unless fields.size >= 5 && fields.all?

      { cpu_total_jiffies: fields.sum, cpu_idle_jiffies: fields[3] + fields[4] }
    end

    # Busy share between two /proc/stat readings; nil when they can't be compared (first sample,
    # counters reset by a reboot, or a different machine behind the same host name).
    def cpu_percent_between(previous, current)
      return nil unless previous && current
      return nil if previous[:cpu_total_jiffies].nil? || current[:cpu_total_jiffies].nil?

      total = current[:cpu_total_jiffies] - previous[:cpu_total_jiffies]
      idle = current[:cpu_idle_jiffies] - previous[:cpu_idle_jiffies]
      return nil unless total.positive? && idle.between?(0, total)

      (100.0 * (total - idle) / total).round(2)
    end

    # `df -P -k /`: a header, then "Filesystem 1024-blocks Used Available Capacity Mounted-on".
    # Used + Available rather than 1024-blocks: the blocks reserved for root are in neither, and a
    # disk is "full" for the app when Available hits 0.
    def df(text)
      row = text.to_s.lines.drop(1).map(&:split).find { |fields| fields.size >= 6 }
      return {} unless row

      used, available = integer(row[2]), integer(row[3])
      return {} unless used && available

      { disk_total_bytes: (used + available) * 1024, disk_used_bytes: used * 1024 }
    end
  end
end
