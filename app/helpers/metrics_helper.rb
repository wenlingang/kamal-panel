# Resource metrics: number formatting and the hand-written SVG line charts of the metrics tab and
# the overview card. Server-rendered, no chart library: the axes, gridlines and lines are plain SVG
# built with tag helpers (so every label is escaped), coloured by the --chart-* tokens. Hover
# read-outs come from the metrics-chart Stimulus controller; without JS the legend and the
# current-values table carry the same numbers, and each chart's aria-label says them in words.
module MetricsHelper
  CHART_WIDTH = 640
  CHART_HEIGHT = 200
  CHART_PAD = { left: 56, right: 12, top: 10, bottom: 24 }.freeze
  # Distinct line colours (--chart-1 … --chart-6); after that they repeat dashed.
  CHART_COLORS = 6
  BINARY_UNITS = %w[B KiB MiB GiB TiB].freeze
  # Usage at or above these reads as a warning / critical in the current-values tables.
  WARN_PERCENT = 80
  CRITICAL_PERCENT = 90

  # 0 → "0 B", 356_515_840 → "340 MiB", 1_288_490_189 → "1.2 GiB".
  def format_bytes(bytes)
    return placeholder("—") if bytes.nil?

    value, unit = scale_bytes(bytes.to_f)
    "#{trim_number(value)} #{unit}"
  end

  # 12.34 → "12%", 4.56 → "4.6%", 0.04 → "0.04%".
  def format_percent(value)
    return placeholder("—") if value.nil?

    "#{trim_number(value.to_f)}%"
  end

  def format_load(value)
    return placeholder("—") if value.nil?

    format("%.2f", value)
  end

  def format_metric(value, unit)
    case unit
    when :bytes then format_bytes(value)
    when :percent then format_percent(value)
    else format_load(value)
    end
  end

  # "warn" / "critical" / nil for a usage percentage.
  def usage_level(percent)
    return nil if percent.nil?

    if percent >= CRITICAL_PERCENT then "critical"
    elsif percent >= WARN_PERCENT then "warn"
    end
  end

  # A percentage cell value that is never colour-only: past a threshold it gets a word too.
  def usage_value(percent)
    level = usage_level(percent)
    text = format_percent(percent)
    return text unless level

    safe_join([ tag.span(text, class: "usage-#{level}"), " ", tag.span(t("metrics.levels.#{level}"), class: "usage-tag usage-#{level}") ])
  end

  # series: [Metrics::AppMetrics::Series]; references: [{ label:, value: }] drawn as dashed lines
  # (a memory limit, the CPU count next to load). unit: :percent / :bytes / :number.
  def metrics_chart(title:, series:, range:, unit:, y_max: nil, references: [])
    references = references.reject { |ref| ref[:value].nil? }
    top, step = chart_scale(series.flat_map(&:values) + references.map { |ref| ref[:value] }, unit:, fixed: y_max)
    geometry = ChartGeometry.new(range.from, range.to, top, step)

    tag.figure(class: "chart", data: { controller: "metrics-chart", metrics_chart_data_value: chart_hover_data(series, geometry, unit).to_json }) do
      safe_join([
        tag.figcaption(title, class: "chart-title"),
        tag.div(class: "chart-plot", data: { metrics_chart_target: "plot", action: "pointermove->metrics-chart#move pointerleave->metrics-chart#leave" }) do
          safe_join([
            chart_svg(series, references, geometry, range, unit, title),
            tag.div(class: "chart-tooltip", hidden: true, data: { metrics_chart_target: "tooltip" })
          ])
        end,
        chart_legend(series, references, unit)
      ])
    end
  end

  # The overview card's tiny CPU line: no axes, just the shape of the last hour.
  def metrics_sparkline(points, from:, to:, label:)
    values = points.map(&:last).compact
    return "".html_safe if values.empty?

    width, height = 120, 24
    top = [ values.max, 1.0 ].max
    span = (to - from).to_f
    coords = points.filter_map do |time, value|
      next if value.nil?

      [ ((time - from) / span * width).clamp(0, width).round(1), (height - 1 - (value / top * (height - 2))).round(1) ]
    end
    path = "M" + coords.map { |x, y| "#{x} #{y}" }.join(" L")

    tag.svg(class: "sparkline", viewBox: "0 0 #{width} #{height}", role: "img", "aria-label": label,
            preserveAspectRatio: "none") do
      tag.path(d: path, class: "chart-line chart-c-0")
    end
  end

  # Maps time / value to SVG coordinates inside the padded plot area.
  class ChartGeometry
    attr_reader :top, :step

    def initialize(from, to, top, step)
      @from = from
      @span = (to - from).to_f
      @top = top.to_f
      @step = step.to_f
    end

    # Gridline values: multiples of the step, so every axis label is a round number.
    def ticks = (0..(top / step).round).map { |i| i * step }

    def left = CHART_PAD[:left]
    def right = CHART_WIDTH - CHART_PAD[:right]
    def upper = CHART_PAD[:top]
    def lower = CHART_HEIGHT - CHART_PAD[:bottom]

    def x(time) = (left + ((time - @from) / @span).clamp(0, 1) * (right - left)).round(1)
    def y(value) = (lower - (value.to_f / top).clamp(0, 1) * (lower - upper)).round(1)
  end

  private
    def axis_label(value, unit)
      unit == :number ? trim_number(value) : format_metric(value, unit).to_s
    end

    def scale_bytes(bytes)
      exponent = 0
      while bytes.abs >= 1024 && exponent < BINARY_UNITS.size - 1
        bytes /= 1024.0
        exponent += 1
      end
      [ bytes, BINARY_UNITS[exponent] ]
    end

    def trim_number(value)
      digits = if value.abs >= 10 || value.zero? then 0
      elsif value.abs >= 1 then 1
      else 2
      end
      number_with_precision(value, precision: digits, strip_insignificant_zeros: true)
    end

    # [axis maximum, gridline step]: a round maximum just above the data in 1 / 2 / 2.5 / 5 × 10ⁿ
    # steps, in binary units for bytes so the gridlines land on 256 MiB rather than 268.4 MB.
    def chart_scale(values, unit:, fixed: nil)
      return [ fixed.to_f, fixed.to_f / 4 ] if fixed

      max = values.compact.max.to_f
      floor = unit == :bytes ? 1024**2 : 1
      max = [ max, floor ].max
      base = unit == :bytes ? 1024**[ (Math.log(max) / Math.log(1024)).floor, 0 ].max : 1
      step = nice_step(max / base / 4.0)
      [ (max / base / step).ceil * step * base, step * base ]
    end

    def nice_step(raw)
      magnitude = 10**Math.log10(raw).floor
      [ 1, 2, 2.5, 5, 10 ].map { |n| n * magnitude }.find { |n| n >= raw }
    end

    def chart_svg(series, references, geometry, range, unit, title)
      tag.svg(class: "chart-svg", viewBox: "0 0 #{CHART_WIDTH} #{CHART_HEIGHT}", role: "img",
              "aria-label": chart_summary(title, series, unit)) do
        safe_join([
          y_grid(geometry, unit),
          x_grid(geometry, range),
          *references.map { |ref| reference_line(ref, geometry, unit) },
          *series.each_with_index.map { |entry, index| series_path(entry, index, geometry, range) },
          tag.line(class: "chart-cursor", x1: 0, x2: 0, y1: geometry.upper, y2: geometry.lower, hidden: true,
                   data: { metrics_chart_target: "cursor" })
        ])
      end
    end

    def y_grid(geometry, unit)
      safe_join(geometry.ticks.map do |value|
        y = geometry.y(value)
        safe_join([
          tag.line(class: "chart-grid", x1: geometry.left, x2: geometry.right, y1: y, y2: y),
          tag.text(axis_label(value, unit), class: "chart-axis", x: geometry.left - 6, y: y + 4, "text-anchor": "end")
        ])
      end)
    end

    X_TICKS = { "1h" => 10.minutes, "6h" => 1.hour, "24h" => 4.hours, "7d" => 1.day }.freeze

    # Ticks on round local times (every 10 minutes … every midnight).
    def x_grid(geometry, range)
      step = X_TICKS.fetch(range.key, 1.hour).to_i
      offset = range.from.utc_offset
      first = (((range.from.to_i + offset) / step.to_f).ceil * step) - offset
      ticks = (first..range.to.to_i).step(step).map { |seconds| Time.zone.at(seconds) }
      format = range.key == "7d" ? "%m-%d" : "%H:%M"

      safe_join(ticks.map do |time|
        x = geometry.x(time)
        safe_join([
          tag.line(class: "chart-grid", x1: x, x2: x, y1: geometry.upper, y2: geometry.lower),
          tag.text(time.strftime(format), class: "chart-axis", x: x, y: CHART_HEIGHT - 6, "text-anchor": "middle")
        ])
      end)
    end

    def reference_line(ref, geometry, unit)
      y = geometry.y(ref[:value])
      tag.line(class: "chart-ref", x1: geometry.left, x2: geometry.right, y1: y, y2: y) do
        tag.title("#{ref[:label]}: #{axis_label(ref[:value], unit)}")
      end
    end

    # One path per series, broken where samples are missing (a host that couldn't be read draws a
    # gap, not a line across it). A lone sample between gaps gets a dot, since a one-point path
    # draws nothing.
    def series_path(entry, index, geometry, range)
      segments = []
      previous = nil
      entry.points.each do |time, value|
        if value.nil?
          previous = nil
          next
        end
        segments << [] if previous.nil? || time - previous > range.gap_seconds
        segments.last << [ geometry.x(time), geometry.y(value) ]
        previous = time
      end

      css = series_class(index)
      d = segments.select { |seg| seg.size > 1 }.map { |seg| "M" + seg.map { |x, y| "#{x} #{y}" }.join(" L") }.join(" ")
      dots = segments.select { |seg| seg.size == 1 }.map { |((x, y))| tag.circle(cx: x, cy: y, r: 2, class: "chart-dot #{css}") }

      tag.g do
        safe_join([ (tag.path(d:, class: "chart-line #{css}") if d.present?), *dots ].compact)
      end
    end

    def series_class(index)
      class_names("chart-c-#{index % CHART_COLORS}", "chart-dashed": index >= CHART_COLORS)
    end

    def chart_legend(series, references, unit)
      return "".html_safe if series.empty? && references.empty?

      tag.ul(class: "chart-legend") do
        items = series.each_with_index.map do |entry, index|
          tag.li do
            safe_join([ legend_swatch("chart-line #{series_class(index)}"), " ",
                        tag.span(entry.label, class: "mono"), " ",
                        tag.span(format_metric(entry.latest, unit), class: "chart-legend-value") ])
          end
        end
        items += references.map do |ref|
          tag.li do
            safe_join([ legend_swatch("chart-ref"), " ", tag.span(ref[:label]), " ",
                        tag.span(axis_label(ref[:value], unit), class: "chart-legend-value") ])
          end
        end
        safe_join(items)
      end
    end

    def legend_swatch(css)
      tag.svg(class: "chart-swatch", viewBox: "0 0 16 4", "aria-hidden": "true") do
        tag.line(x1: 0, y1: 2, x2: 16, y2: 2, class: css)
      end
    end

    # "CPU: web @ 10.1.0.11 latest 12%, highest 40%; …" for screen readers.
    def chart_summary(title, series, unit)
      return t("metrics.chart.no_data", title:) if series.all? { |entry| entry.values.empty? }

      parts = series.reject { |entry| entry.values.empty? }.map do |entry|
        t("metrics.chart.summary_series", label: entry.label, latest: strip_tags(format_metric(entry.latest, unit).to_s),
                                          max: strip_tags(format_metric(entry.values.max, unit).to_s))
      end
      "#{title}: #{parts.join(t('metrics.chart.separator'))}"
    end

    # What the hover read-out shows: per bucket time, its x position and each series' value.
    def chart_hover_data(series, geometry, unit)
      times = series.flat_map { |entry| entry.points.map(&:first) }.uniq.sort
      lookup = series.map { |entry| entry.points.to_h }
      {
        x: times.map { |time| geometry.x(time) },
        width: CHART_WIDTH,
        t: times.map { |time| l(time, format: :metrics_point) },
        s: series.each_with_index.map do |entry, index|
          { l: entry.label, c: index % CHART_COLORS,
            v: times.map { |time| (value = lookup[index][time]).nil? ? nil : strip_tags(format_metric(value, unit).to_s) } }
        end
      }
    end
end
