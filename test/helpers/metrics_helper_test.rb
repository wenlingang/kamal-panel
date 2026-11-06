require "test_helper"

class MetricsHelperTest < ActionView::TestCase
  include ApplicationHelper
  Series = Metrics::AppMetrics::Series

  setup do
    @now = Time.zone.parse("2026-11-05 12:00:00")
    @range = Metrics::TimeRange.new("1h", now: @now)
  end

  def points(*values, from: @now - 30.minutes)
    values.each_with_index.map { |value, i| [ from + i.minutes, value ] }
  end

  test "bytes in binary units, percentages and loads" do
    assert_equal "0 B", format_bytes(0)
    assert_equal "512 B", format_bytes(512)
    assert_equal "340 MiB", format_bytes(340 * 1024**2)
    assert_equal "1.2 GiB", format_bytes((1.2 * 1024**3).round)
    assert_equal "12%", format_percent(12.34)
    assert_equal "4.6%", format_percent(4.56)
    assert_equal "0.04%", format_percent(0.04)
    assert_equal "0.52", format_load(0.523)
    assert_includes format_bytes(nil), "—"
  end

  test "usage past 80% / 90% gets a word, not only a colour" do
    assert_equal "50%", usage_value(50)
    assert_includes usage_value(85), I18n.t("metrics.levels.warn")
    assert_includes usage_value(95), I18n.t("metrics.levels.critical")
    assert_includes usage_value(95), "usage-critical"
  end

  test "a chart is well-formed SVG with gridlines, axis labels, a legend and a spoken summary" do
    html = metrics_chart(title: "CPU", unit: :percent, range: @range,
                         series: [ Series.new(key: "a", label: "web @ 10.0.0.1", points: points(10, 20, 30)) ])
    doc = Nokogiri::XML(html) { |config| config.strict }

    svg = doc.at_css("svg.chart-svg")
    assert_equal "img", svg["role"]
    assert_includes svg["aria-label"], "web @ 10.0.0.1"
    assert_includes svg["aria-label"], "30%"
    assert_operator doc.css("line.chart-grid").size, :>=, 5
    assert_equal %w[0% 10% 20% 30%], doc.css("text.chart-axis").map(&:text).first(4), "round tick labels"
    assert_equal 1, doc.css("path.chart-line").size
    assert_equal "web @ 10.0.0.1", doc.at_css(".chart-legend li .mono").text
    data = JSON.parse(doc.at_css("figure")["data-metrics-chart-data-value"])
    assert_equal 3, data["x"].size
    assert_equal [ "10%", "20%", "30%" ], data["s"].first["v"]
  end

  test "labels are escaped" do
    html = metrics_chart(title: "<b>t</b>", unit: :bytes, range: @range,
                         series: [ Series.new(key: "x", label: "<script>alert(1)</script>", points: points(1024, 2048)) ],
                         references: [ { label: "<i>limit</i>", value: 4096 } ])

    assert_not_includes html, "<script>"
    assert_not_includes html, "<i>limit"
    assert_includes html, "&lt;script&gt;"
  end

  test "missing samples break the line; a lone sample becomes a dot" do
    gap = points(10, 20) + [ [ @now - 20.minutes, 30 ] ] + [ [ @now - 10.minutes, 40 ], [ @now - 9.minutes, 50 ] ]
    doc = Nokogiri::HTML5.fragment(metrics_chart(title: "CPU", unit: :percent, range: @range,
                                                  series: [ Series.new(key: "a", label: "a", points: gap) ]))

    assert_equal 2, doc.at_css("path.chart-line")["d"].scan("M").size
    assert_equal 1, doc.css("circle.chart-dot").size
  end

  test "an empty chart says so and draws no line" do
    doc = Nokogiri::HTML5.fragment(metrics_chart(title: "CPU", unit: :percent, range: @range,
                                                  series: [ Series.new(key: "a", label: "a", points: []) ]))

    assert_equal I18n.t("metrics.chart.no_data", title: "CPU"), doc.at_css("svg")["aria-label"]
    assert_empty doc.css("path.chart-line")
  end

  test "byte axes step in binary units; a fixed maximum is honoured" do
    doc = Nokogiri::HTML5.fragment(metrics_chart(title: "mem", unit: :bytes, range: @range,
                                                  series: [ Series.new(key: "a", label: "a", points: points(1.3 * 1024**3)) ]))
    assert_equal [ "0 B", "512 MiB", "1 GiB", "1.5 GiB" ], doc.css("text.chart-axis").map(&:text).first(4)

    doc = Nokogiri::HTML5.fragment(metrics_chart(title: "use", unit: :percent, range: @range, y_max: 100,
                                                  series: [ Series.new(key: "a", label: "a", points: points(3)) ]))
    assert_equal %w[0% 25% 50% 75% 100%], doc.css("text.chart-axis").map(&:text).first(5)
  end

  test "sparkline" do
    svg = metrics_sparkline(points(1, 5, 3), from: @now - 1.hour, to: @now, label: "CPU 3%")
    doc = Nokogiri::XML(svg) { |config| config.strict }

    assert_equal "CPU 3%", doc.root["aria-label"]
    assert_match(/\AM[\d. L]+\z/, doc.at_css("path")["d"])
    assert_equal "", metrics_sparkline([], from: @now - 1.hour, to: @now, label: "x")
  end
end
