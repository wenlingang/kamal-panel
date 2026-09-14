require "test_helper"

# 第 5 批收的是 Ruby 侧的文案：flash、模型校验消息，以及几个由服务对象产出的
# 展示串。这些【不】经过视图里的 t()，所以 views_have_no_bare_chinese_test
# 那条守卫看不见它们，LocaleSmokeTest 也抓不到——它只断言渲染不抛异常，而一句
# 写死的中文渲染得好好的。
#
# 换句话说：没有这个文件，第 5 批做没做、做全没做，没有任何测试知道。
class RubySideI18nTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:two)
    @admin.update!(locale: "en")
    @managed_app = ManagedApp.create!(name: "blog",
                                      config_yaml: file_fixture("simple_deploy.yml").read,
                                      destination: "production")
    sign_in_as @admin
  end

  test "flash 按当前语言渲染" do
    patch user_path(users(:one)), params: { user: { role: "ops", nickname: "Li" } }

    follow_redirect!
    assert_select ".flash", text: /Updated one@example\.com/
  end

  test "总览的状态徽章与筛选下拉按当前语言渲染" do
    get root_path

    assert_response :success
    assert_select ".status-badge", text: /Not collected yet/
    assert_select "select.filter-status option", text: "Version mismatch"
    assert_select "select.filter-status option", text: "Config cannot be parsed"
  end

  test "模型校验消息按当前语言渲染" do
    post credentials_path, params: { credential: { name: "bad", value: "not a key" } }

    assert_response :unprocessable_entity
    assert_select "ul.errors li", text: /is not a usable SSH private key/
  end

  # 状态标签此前是一个在类加载时就求值的常量哈希（ManagedAppStatus::LEVELS）。
  # 那种写法下，标签会被永久钉死在启动时的 locale 上，之后任何一次语言切换都
  # 不会反映到它——这正是设计 13 §10 提醒的那个坑。
  test "状态标签跟着 locale 走，不是加载时定死的" do
    assert_equal "Version mismatch", I18n.with_locale(:en) { ManagedAppStatus.label_for(:drift) }
    assert_equal "版本不一致", I18n.with_locale(:"zh-CN") { ManagedAppStatus.label_for(:drift) }
  end

  test "部署历史的来源与观测两列跟着 locale 走" do
    event = DeployEvent.create!(managed_app: @managed_app, version: "abc1234",
                                source: "inferred", observed_at: Time.current)

    assert_equal "Inferred by panel", I18n.with_locale(:en) { event.source_text }
    assert_equal "面板推断", I18n.with_locale(:"zh-CN") { event.source_text }
    assert_equal "Observed by the panel", I18n.with_locale(:en) { event.observation_delay_text }
  end
end
