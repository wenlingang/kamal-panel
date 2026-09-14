require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]

  # 提交 SSH 私钥现在会触发一次子进程（SshKeyValidator，见
  # app/models/ssh_key_validator.rb）：每次都是冷启动一个新 Ruby 进程去
  # require net-ssh，正常情况下几百毫秒，但在系统测试这种本来就在跑
  # Puma + headless Chrome、资源比较紧张的环境里，偶尔会顶到 Capybara 默认
  # 的 2 秒等待上限，导致间歇性的假失败（不是校验逻辑的问题，纯粹是测试
  # 环境下这次冷启动恰好慢了一点）。放宽到 5 秒只影响测试环境的等待预算，
  # 不改变生产环境里子进程本身的硬超时（那个由 SshKeyValidator::DEFAULT_TIMEOUT
  # 控制，是完全独立的另一件事）。
  Capybara.default_max_wait_time = 5

  # 系统测试跑在真实浏览器里，SessionTestHelper#sign_in_as 那种直接塞 cookie 的
  # 办法用不上（不同进程/会话），所以走真实的登录表单。
  # sessions#create 有 rate_limit（10 次 / 3 分钟，按 IP 计）。system 测试
  # 全部从 127.0.0.1 登录，跑全套时这个计数会跨测试累加——第 11 个登录的
  # 测试会被重定向回登录页，失败原因看起来像"密码不对"，其实和被测行为
  # 无关。限流用的是 Rails.cache，所以每个测试前清一次。
  setup { Rails.cache.clear }

  def sign_in_as(user, password: "secret123456")
    visit new_session_path
    fill_in "邮箱地址", with: user.email_address
    fill_in "密码", with: password
    click_on "登录"

    # 真实浏览器里点击提交后跳转是异步的；下一步操作（比如再次 visit）
    # 如果紧跟在 click_on 后面执行，可能会跟这次跳转赛跑，命中登录页
    # 还没跳走的瞬间。等登录表单消失，确保跳转已经完成。
    assert_no_selector "input[name='password']"
  end

  # Net::HTTP.post_form 不支持自定义 header，这里补一个。
  def post_hook_report(uri, token, params)
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{token}"
    request.set_form_data(params)
    Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
  end
end
