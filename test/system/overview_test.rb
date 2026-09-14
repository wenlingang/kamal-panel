require "application_system_test_case"

class OverviewTest < ApplicationSystemTestCase
  setup do
    Rails.cache.clear # cached_app_hosts 缓存键含 id，SQLite 回滚后可能复用 id

    # 两台机器都配置在 deploy.yml 里，跟下面 observe() 用到的主机对得上——
    # 否则"配置里有、但没采集过的机器"这条规则会把这几个测试场景也判成
    # 机器失联。
    @app = ManagedApp.create!(
      name: "blog", config_yaml: file_fixture("two_host_deploy.yml").read,
      destination: "production"
    )

    # 只看总览是 ops 就能做的事，不需要 admin。
    sign_in_as(User.create!(email_address: "ops@example.com", password: "secret123456"))
  end

  def observe(host:, version:, docker_status: "running")
    Observation.create!(
      managed_app: @app, host: host, role: "web",
      container_name: "blog-web-production-#{version}",
      version: version, docker_status: docker_status,
      reachable: true, observed_at: Time.current
    )
  end

  test "版本一致时显示正常" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", version: "aaaaaaa")

    visit root_path

    assert_text "正常"
    assert_text "aaaaaaa"
  end

  test "版本漂移被醒目呈现，且带文字说明而不只是颜色" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", version: "bbbbbbb")

    visit root_path

    assert_text "版本不一致"
    assert_text "2 个版本并存"
  end

  test "总览显示数据年龄" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", version: "aaaaaaa")

    visit root_path

    assert_text "前"
  end

  # unobserved（上报了但观测不到）与 unfinished（开了头没收尾）是两类
  # 不同的告警，之前总览格子里两者共用一句"上报未验证"文案，对 unfinished
  # 是错的——它压根没上报过"成功"，谈不上"未验证"。
  test "只有开了头没收尾的告警时，总览徽章说的是部署未收尾" do
    DeployEvent.create!(managed_app: @app, version: "ccccccc", source: "hook",
                        started_at: 16.minutes.ago)

    visit root_path

    assert_text "部署未收尾"
    assert_no_text "上报未验证"
  end
end
