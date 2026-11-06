require "test_helper"

class MetricsTabTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    sign_in_as users(:two)
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production")
  end

  def sample(at: 1.minute.ago, mem_percent: 40)
    ContainerMetric.create!(managed_app: @app, host: "127.0.0.1", container_name: "blog-web-production-abc", source: "web",
                            kind: "app", version: "abc", cpu_percent: 12.5, mem_bytes: 300 * 1024**2,
                            mem_limit_bytes: 512 * 1024**2, mem_percent:, pids: 9, sampled_at: at.change(sec: 0))
    HostMetric.create!(managed_app: @app, host: "127.0.0.1", load1: 0.7, cpus: 2, cpu_percent: 33, mem_total_bytes: 4 * 1024**3,
                       mem_available_bytes: 1024**3, disk_total_bytes: 100 * 1024**3, disk_used_bytes: 95 * 1024**3,
                       sampled_at: at.change(sec: 0))
  end

  test "the metrics tab sits between logs and actions" do
    get managed_app_path(@app, tab: "metrics")

    tabs = css_select("nav.tabs a.tab").map { |a| a.text.strip }
    assert_equal I18n.t("managed_apps.show.tabs.metrics"), tabs[tabs.index(I18n.t("managed_apps.show.tabs.logs")) + 1]
    assert_select "nav.tabs a.tab[aria-current=page]", text: I18n.t("managed_apps.show.tabs.metrics")
  end

  test "with samples: current values, warnings in words, charts and the range control" do
    sample(mem_percent: 93)

    get managed_app_path(@app, tab: "metrics", range: "24h")

    assert_response :success
    assert_select ".metrics-table td.mono", text: "127.0.0.1"
    assert_select ".metrics-table td", text: /300 MiB/
    assert_select ".metrics-table .usage-critical", text: I18n.t("metrics.levels.critical")
    assert_select ".metrics-host h4", text: "127.0.0.1"
    assert_select ".metrics-host .usage-critical", minimum: 1 # disk 95%
    assert_select "figure.chart svg.chart-svg[role=img]", 4
    assert_select "figure.chart circle.chart-dot", minimum: 1 # one sample: a dot, not a line
    assert_select "nav.segmented a.segmented-item[aria-current=page]", text: I18n.t("metrics.ranges.24h")
  end

  test "without samples it explains how metrics get collected" do
    get managed_app_path(@app, tab: "metrics")

    assert_select ".empty-state", text: /#{Regexp.escape(I18n.t('metrics.tab.empty_no_key')[0, 10])}/
    assert_select "figure.chart", 0

    @app.update!(ssh_credential: Credential.create!(kind: "ssh_key", name: "k", value: File.read(Rails.root.join("test/fake_host/id_ed25519"))))
    get managed_app_path(@app, tab: "metrics")
    assert_select ".empty-state", text: /SSH/
  end

  test "a config that doesn't parse shows the callout and never reaches parsed_config" do
    sample
    @app.update_column(:config_yaml, "不是配置")
    @app.update_columns(last_poll_error: "boom", last_poll_error_at: Time.current, first_poll_error_at: Time.current)

    get managed_app_path(@app, tab: "metrics")

    assert_response :success
    assert_select ".callout", text: I18n.t("metrics.tab.config_unparseable")
  end

  test "the overview card shows the latest container totals and a sparkline" do
    sample

    get overview_path

    assert_select ".app-card .app-card-metrics", text: /CPU 13%/
    assert_select ".app-card .app-card-metrics", text: /300 MiB/
    assert_select ".app-card .app-card-metrics svg.sparkline[role=img]"
  end
end
