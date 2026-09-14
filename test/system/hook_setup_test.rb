require "application_system_test_case"
require "net/http"

# 这条守的是别的测试都守不住的那种失败：端点单测过、页面单测过，
# 但页面给出的参数名与端点期望的不一致，于是用户照抄下来永远收不到数据。
class HookSetupTest < ApplicationSystemTestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    sign_in_as(User.create!(email_address: "op@example.com", password: "secret123456",
                            role: "admin"))
  end

  test "照着页面上的脚本发一次请求，部署历史就出现一行" do
    visit managed_app_path(@app)
    click_on "生成上报 token"

    script = find("pre", text: "phase=succeeded").text
    # 脚本里 token 紧挨着 curl -H 参数的收尾双引号（没有空格），\S+ 会把
    # 那个引号也吞进去，导致这里取到的 token 比页面/脚本里实际的多一个字符，
    # 于是永远 401——所以要求捕获组后面紧跟着这个收尾引号。
    token = script[/Bearer (\S+)"/, 1]
    assert token.present?, "页面上的脚本里应当带着 token"

    # URL 与参数名都从渲染出的脚本文本里解析，而不是测试自己手写——手写常量
    # 意味着 HookScript 万一改了参数名或端点路径，这条测试也照样绿，恰恰
    # 守不住"页面给出的脚本与端点期望的参数名不一致"这条它自称要守的东西。
    url = script[/-X POST "([^"]+)"/, 1]
    assert url.present?, "脚本里应当有一行 curl 指向上报端点"
    path = URI(url).path

    param_names = script.scan(/-d\s+([A-Za-z_]+)=/).flatten
    assert_equal %w[phase service destination version performer command recorded_at].sort,
                param_names.uniq.sort,
                "页面给出的参数名要和端点期望的完全一致（多一个少一个都会让用户照抄却收不到数据）"

    values = { "phase" => "succeeded", "service" => "blog", "destination" => "production",
              "version" => "aaaaaaa", "performer" => "ci", "command" => "deploy",
              "recorded_at" => Time.current.iso8601 }
    request_params = param_names.index_with { |name| values.fetch(name) }

    # 直接打 Capybara 起的那个 server，用的是脚本里出现的 URL 与参数名
    uri = URI.join(page.server_url, path)
    response = post_hook_report(uri, token, request_params)

    assert_equal "204", response.code
    assert_equal 1, @app.deploy_events.count

    visit managed_app_path(@app)
    assert_text "aaaaaaa"
  end

  test "token 只显示一次" do
    visit managed_app_path(@app)
    click_on "生成上报 token"
    assert_text "只显示这一次"

    visit managed_app_path(@app)
    assert_no_text "只显示这一次"
  end
end
