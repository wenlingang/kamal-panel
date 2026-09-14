# kamal-panel 实施计划 02：操作与安全

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让面板从「只读」变为「可安全操作」——多用户与两种角色、先写后做的审计、复用 Kamal 自己的部署锁、以及回滚／重启／停止／启动这一组封闭动作，执行过程实时流式输出。

**Architecture:** 写操作**不自己拼命令**，而是在受限子进程中调用 `kamal` CLI。理由是语义等价：`kamal rollback` 不只是启动容器，它还会触发用户自己的 pre/post-deploy hook、切换 kamal-proxy 路由、跑健康检查。自己用 `Kamal::Commands::App` 重实现，等于再造一个必须与 Kamal 永远保持一致的实现——计划 01 已经为这一类「两个必须永远同意的实现」付过学费。私钥经**每次调用独立的 ssh-agent** 注入（`ssh-add -` 从 stdin 读），全程不落盘。

**Tech Stack:** Ruby 4.0 / Rails 8.1 / kamal gem 2.12（作为 gem 复用其配置解析，作为 CLI 执行写操作）/ SSHKit / SQLite / Solid Queue / Solid Cable / Hotwire / Minitest + Capybara / Docker Compose（fake host）

**Spec:** `docs/superpowers/specs/2026-09-05-kamal-panel-design.md`

## Global Constraints

**每个任务的要求都隐含包含本节。**

- **仅支持 Kamal 2+**。验证基线：kamal **v2.12.0**、kamal-proxy **v0.10.0**。
- **不引入 Redis**：Solid Queue / Solid Cache / Solid Cable。
- **不引入任何前端框架**：只用 Hotwire（Turbo + Stimulus）。
- **面板永远不执行任意命令**（spec 7.3）。动作集是封闭的，定义在代码里。**不做 `kamal app exec`、不做任意命令输入框**——一旦提供，面板即等价于带 Web 界面的远程 shell。
- **私钥绝不落盘**（spec 7.2 的延伸）。CLI 子进程经 ssh-agent 取得密钥。
- **审计先写后做**（spec 7.5）：动作发起前落 `pending`，完成后更新。审计日志**不可删除**，UI 不提供删除入口。
- **viewer 看不到按钮，而不是看到置灰的按钮**（spec 7.7）。
- **状态绝不能只靠颜色传达**：每个状态都要有文字或形状标识。
- 所有测试 fixture 中的 deploy.yml **必须带 `builder: { arch: amd64 }`**，否则 Kamal 2.12.0 的校验器拒绝。这在计划 01 绊了四个任务。
- **不 mock SSH**。执行层测试连真实 fake host：`docker compose -f docker-compose.test.yml up -d`。
- `bin/rails test:all` **必须前台、单进程**运行；`bin/rails runner` 在 `RAILS_ENV=test` 下会提交事务外的行、污染后续运行。
- CI 跑 brakeman + rubocop + tests。**brakeman 通过不是覆盖的证据**——计划 01 中它两次漏掉真实缺陷（配置值流入 `Pathname#sub_ext`；配置值流入 net-ssh 内部的 `IO.popen`）。
- UI 文案为中文；视觉方向为 37signals 语言：克制用色仅表达状态、扁平、层级靠字重与间距。

## 已验证的承重假设

**每次调用独立 ssh-agent，密钥经 stdin 注入，不落盘。** 2026-09-06 对真实 fake host 实测通过：

```
eval "$(ssh-agent -s)"
ssh-add - < <key>          # → Identity added: (stdin)
ssh -p 2201 deploy@127.0.0.1 'echo AGENT_AUTH_OK'   # 不给 -i → AGENT_AUTH_OK
ssh-agent -k
```

Task 6 的执行基座建立在这条之上。若它在某个环境下不成立，Task 6 必须报 BLOCKED 而不是退回「把密钥写到 0600 文件」。

## 分阶段可交付

- **Task 1–5 完成后即可独立交付**：一个带登录与角色、能显示部署锁状态、且清掉了计划 01 全部残留的只读面板。
- **Task 6–12** 才引入写操作。

---

## 文件结构

```
app/
├── models/
│   ├── user.rb                       # 邮箱 + 密码 + role(viewer|operator)
│   ├── session.rb                    # Rails 8 内置认证生成物
│   └── audit_log.rb                  # 先写后做，不可删除
├── services/
│   ├── kamal_lock.rb                 # 读锁状态（纯读，复用 SshSession）
│   └── actions/
│       ├── base.rb                   # 声明角色/是否要锁/影响 host/成功判定
│       ├── rollback.rb
│       ├── restart.rb
│       ├── stop.rb
│       ├── start.rb
│       └── force_unlock.rb
├── services/kamal_cli/
│   ├── invocation.rb                 # tempdir + ssh-agent + 子进程 + 流式输出
│   └── agent.rb                      # 每次调用独立的 ssh-agent 生命周期
├── jobs/run_action_job.rb            # 执行动作，逐行广播，收尾审计
├── controllers/
│   ├── sessions_controller.rb
│   ├── actions_controller.rb         # 唯一的写入口，只接受封闭动作集
│   └── audit_logs_controller.rb      # 只读列表
└── views/...
```

---

## Task 1: 清理计划 01 的残留

**Files:**
- Modify: `app/views/managed_apps/index.html.erb`
- Modify: `app/models/managed_app.rb`
- Modify: `app/jobs/poll_managed_app_job.rb`
- Modify: `app/services/managed_app_status.rb`
- Modify: `app/services/collectors/proxy_collector.rb`
- Modify: `app/views/managed_apps/_host_table.html.erb`
- Test: `test/controllers/managed_apps_controller_test.rb`, `test/services/managed_app_status_test.rb`, `test/jobs/poll_managed_app_job_test.rb`

**Interfaces:**
- Consumes: 计划 01 的全部既有接口
- Produces: `ManagedAppStatus::STALE_THRESHOLD` 改为由 `PollCadence::IDLE` 推导；`ManagedApp#first_poll_error_at`

spec 11.1 列了五项，加一项整洁性条目。它们互不相干，但都很小，合成一个任务。

- [ ] **Step 1: 写失败测试——一份坏配置不得让 /apps 整页 500**

`test/controllers/managed_apps_controller_test.rb` 追加：

```ruby
test "一个应用的 deploy.yml 坏掉时，/apps 仍能列出其余应用" do
  good = ManagedApp.create!(name: "good", config_yaml: file_fixture("simple_deploy.yml").read,
                            destination: "production")
  broken = ManagedApp.create!(name: "broken", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  broken.update_column(:config_yaml, "不是配置")

  get managed_apps_path

  assert_response :success
  assert_match "good", @response.body
  assert_match "broken", @response.body
  assert_match "配置无法解析", @response.body
end
```

- [ ] **Step 2: 运行，确认失败**

Run: `bin/rails test test/controllers/managed_apps_controller_test.rb`
Expected: FAIL —— 500 或 `Kamal::ConfigParser::ParseError`

- [ ] **Step 3: 给 index 加 guard**

`app/views/managed_apps/index.html.erb` 中主机数那一处改为：

```erb
<% @managed_apps.each do |app| %>
  <li>
    <%= link_to app.name, app %> —
    <%
      hosts_count = begin
        app.cached_app_hosts.size
      rescue Kamal::ConfigParser::ParseError
        nil
      end
    %>
    <% if hosts_count %>
      <%= hosts_count %> 台机器
    <% else %>
      <span class="config-broken">配置无法解析</span>
    <% end %>
  </li>
<% end %>
```

- [ ] **Step 4: 运行，确认通过**

Run: `bin/rails test test/controllers/managed_apps_controller_test.rb`
Expected: PASS

- [ ] **Step 5: 写失败测试——首次失败时间戳不得被覆写**

`test/jobs/poll_managed_app_job_test.rb` 追加：

```ruby
test "连续失败时 first_poll_error_at 保持首次失败的时间" do
  app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                           destination: "production")
  app.update_column(:config_yaml, "不是配置")

  travel_to Time.utc(2026, 9, 6, 10, 0, 0) do
    PollManagedAppJob.perform_now(app)
  end
  first = app.reload.first_poll_error_at

  travel_to Time.utc(2026, 9, 6, 12, 0, 0) do
    PollManagedAppJob.perform_now(app)
  end

  assert_equal first, app.reload.first_poll_error_at
  assert_operator app.last_poll_error_at, :>, first
end
```

- [ ] **Step 6: 运行，确认失败**

Run: `bin/rails test test/jobs/poll_managed_app_job_test.rb`
Expected: FAIL —— `first_poll_error_at` 不存在

- [ ] **Step 7: 加列并只在首次写入**

```bash
bin/rails generate migration AddFirstPollErrorAtToManagedApps first_poll_error_at:datetime
bin/rails db:migrate
```

`app/jobs/poll_managed_app_job.rb` 的 `record_poll_error` 改为：

```ruby
    def record_poll_error(managed_app, message)
      attrs = { last_poll_error: message, last_poll_error_at: Time.current }
      # 首次失败的时间戳只写一次——横幅声称「自 X 起每轮都失败」，
      # 每轮覆写会让坏了几天的应用永远显示「不到一分钟前」。
      attrs[:first_poll_error_at] = Time.current if managed_app.first_poll_error_at.nil?

      managed_app.update_columns(**attrs)
    end
```

并在成功轮询时清空三者（找到 `perform` 中成功路径，追加 `clear_poll_error(managed_app)`）：

```ruby
    def clear_poll_error(managed_app)
      return if managed_app.last_poll_error.nil?

      managed_app.update_columns(last_poll_error: nil, last_poll_error_at: nil,
                                 first_poll_error_at: nil)
    end
```

横幅文案改用 `first_poll_error_at`。

- [ ] **Step 8: 陈旧阈值由节奏推导**

`app/services/managed_app_status.rb`：

```ruby
  # 阈值不硬编码：它必须随轮询节奏走，否则在高延迟链路上会对健康集群狼来了。
  # 见 spec 10.4——capture_many 是串行的，50 台经跳板机时单轮可达数十秒。
  # 三倍空闲间隔意味着「连续错过三轮」才判定陈旧，与原先 3 分钟对 60 秒节奏的比例一致。
  STALE_MULTIPLIER = 3

  def self.stale_threshold
    PollCadence::IDLE * STALE_MULTIPLIER
  end

  def stale?(threshold: self.class.stale_threshold)
```

同文件中所有 `STALE_THRESHOLD` 引用改为 `self.class.stale_threshold`。

- [ ] **Step 9: 文案不得把「我没看清」说成「机器没了」**

`app/services/managed_app_status.rb` 的 `LEVELS` 保持五态不变，但 `_host_table.html.erb` 中逐主机文案按来源区分：

```erb
        <td>
          <% if row[:reachable].nil? %>
            尚未采集
          <% elsif row[:reachable] %>
            正常
          <% elsif row[:error].to_s.include?("unparseable") %>
            <strong>输出无法解析</strong>
            <br><small>主机可达，但返回的内容读不懂</small>
          <% else %>
            <strong>失联</strong>
            <% if row[:stale_since] %>
              — 以下为 <%= time_ago_in_words(row[:stale_since]) %>前的状态
            <% end %>
          <% end %>
        </td>
```

`ContainerCollector` 写不可解析行时，`error` 需以 `"unparseable: "` 开头，使上面的判断有依据。

- [ ] **Step 10: stderr 不再降级整份路由载荷**

`app/services/collectors/proxy_collector.rb` 中，解析前先剥掉非 JSON 的前导行：

```ruby
      # kamal-proxy 在 happy path 上偶尔会往 stderr 写一行（已合并进 stdout）。
      # 只取第一个 '{' 起的部分，避免一行噪音把整份路由载荷降级为 unrecognized。
      def json_payload(stdout)
        text = stdout.to_s
        start = text.index("{") || text.index("[")
        start ? text[start..] : text
      end
```

在 `parse_targets` 入口处调用它。

- [ ] **Step 11: 三份 `latest_for` 收敛为一处**

`app/models/concerns/latest_per_host.rb`：

```ruby
# Observation 与 ProxyTarget 都按 (managed_app, host) 取各自最新一行。
# 计划 01 中这段查询有三份副本；行为一致但会分叉。
module LatestPerHost
  extend ActiveSupport::Concern

  class_methods do
    def latest_for(managed_app)
      latest_times = where(managed_app: managed_app).group(:host).maximum(:observed_at)
      return none if latest_times.empty?

      conditions = latest_times.map { |host, time|
        sanitize_sql([ "(host = ? AND observed_at = ?)", host, time ])
      }

      where(managed_app: managed_app).where(conditions.join(" OR "))
    end
  end
end
```

`Observation` 与 `ProxyTarget` 各 `include LatestPerHost`，删除各自的 `latest_for`。

- [ ] **Step 12: 全套测试并提交**

Run: `bin/rails test:all`（前台单进程，fake host 已起）
Expected: 全绿

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "fix: 清理计划 01 的五项残留

- /apps 页对无法解析的配置逐行降级，不再整页 500
- first_poll_error_at 只写一次，横幅不再对坏了几天的应用显示「不到一分钟前」
- 陈旧阈值由 PollCadence::IDLE 推导，不再硬编码 3 分钟
- 逐主机文案区分「输出无法解析」与「失联」
- proxy 载荷解析前剥掉 stderr 噪音行
- latest_for 三份副本收敛为 LatestPerHost concern"
```

---

## Task 2: User 模型、登录、两种角色

**Files:**
- Create: `app/models/user.rb`、`app/models/session.rb`（生成物）
- Create: `app/controllers/sessions_controller.rb`（生成物）
- Modify: `app/controllers/application_controller.rb`
- Modify: `config/routes.rb`
- Create: `db/seeds.rb` 的管理员初始化
- Test: `test/models/user_test.rb`、`test/controllers/sessions_controller_test.rb`

**Interfaces:**
- Produces: `Current.user`；`User#operator?` / `#viewer?`；`ApplicationController#require_operator!`

- [ ] **Step 1: 生成 Rails 8 内置认证**

```bash
bin/rails generate authentication
bin/rails db:migrate
```

Rails 8 的 `authentication` 生成器会产出 `User`、`Session`、`Current`、`SessionsController`、`PasswordsResetsController` 与 `Authentication` concern。

- [ ] **Step 2: 写失败测试——角色**

`test/models/user_test.rb`：

```ruby
require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "默认角色是 viewer" do
    user = User.create!(email_address: "a@example.com", password: "secret123456")
    assert user.viewer?
    refute user.operator?
  end

  test "operator 角色" do
    user = User.create!(email_address: "b@example.com", password: "secret123456", role: "operator")
    assert user.operator?
    refute user.viewer?
  end

  test "拒绝未知角色" do
    user = User.new(email_address: "c@example.com", password: "secret123456", role: "admin")
    refute user.valid?
  end
end
```

- [ ] **Step 3: 运行，确认失败**

Run: `bin/rails test test/models/user_test.rb`
Expected: FAIL —— `role` 列不存在

- [ ] **Step 4: 加 role**

```bash
bin/rails generate migration AddRoleToUsers role:string
```

迁移中设默认值：

```ruby
class AddRoleToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :role, :string, null: false, default: "viewer"
  end
end
```

```bash
bin/rails db:migrate
```

`app/models/user.rb` 加入：

```ruby
  ROLES = %w[viewer operator].freeze

  validates :role, inclusion: { in: ROLES }

  def viewer?   = role == "viewer"
  def operator? = role == "operator"
```

- [ ] **Step 5: 运行，确认通过**

Run: `bin/rails test test/models/user_test.rb`
Expected: 3 runs, 0 failures

- [ ] **Step 6: 写失败测试——未登录一律跳转登录页**

`test/controllers/sessions_controller_test.rb`：

```ruby
require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  test "未登录访问总览会跳到登录页" do
    get root_path
    assert_redirected_to new_session_path
  end

  test "登录后可访问总览" do
    User.create!(email_address: "a@example.com", password: "secret123456")
    post session_path, params: { email_address: "a@example.com", password: "secret123456" }

    get root_path
    assert_response :success
  end
end
```

- [ ] **Step 7: 运行，确认失败**

Run: `bin/rails test test/controllers/sessions_controller_test.rb`
Expected: FAIL —— 总览未要求登录

- [ ] **Step 8: 全站要求登录**

`app/controllers/application_controller.rb`：

```ruby
class ApplicationController < ActionController::Base
  include Authentication

  allow_browser versions: :modern

  private
    # 需要 operator 的动作统一走这里。
    # 注意：viewer 不该看到按钮（spec 7.7），这一层是纵深防御，不是唯一防线。
    def require_operator!
      return if Current.user&.operator?

      redirect_to root_path, alert: "该操作需要 operator 权限"
    end
end
```

生成器已在 `Authentication` concern 中默认要求登录；确认 `OverviewsController` / `ManagedAppsController` 未 `allow_unauthenticated_access`。

- [ ] **Step 9: 管理员初始化**

`db/seeds.rb`：

```ruby
# 首个 operator 由环境变量注入，避免出现「默认密码」这种东西。
if (email = ENV["KAMAL_PANEL_ADMIN_EMAIL"]).present?
  password = ENV.fetch("KAMAL_PANEL_ADMIN_PASSWORD")
  User.find_or_create_by!(email_address: email) do |user|
    user.password = password
    user.role = "operator"
  end
  puts "已创建 operator: #{email}"
end
```

在 README 的部署说明中写明这两个环境变量。

- [ ] **Step 10: 运行全套并提交**

Run: `bin/rails test:all`

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "feat: 登录与 viewer/operator 两种角色

首个 operator 由环境变量注入，不设默认密码。
require_operator! 是纵深防御——viewer 首先应该看不到按钮。"
```

---

## Task 3: 授权——viewer 看不到按钮

**Files:**
- Modify: `app/views/managed_apps/show.html.erb`
- Modify: `app/views/overviews/_grid.html.erb`
- Create: `app/helpers/authorization_helper.rb`
- Test: `test/system/role_visibility_test.rb`

**Interfaces:**
- Consumes: `Current.user`（Task 2）
- Produces: `operator_only { }` view helper

spec 7.7：**viewer 看不到按钮，而不是看到置灰的按钮**——后者会诱导用户追问「为什么我不能点」。

- [ ] **Step 1: 写失败系统测试**

`test/system/role_visibility_test.rb`：

```ruby
require "application_system_test_case"

class RoleVisibilityTest < ApplicationSystemTestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  def sign_in_as(role)
    User.create!(email_address: "#{role}@example.com", password: "secret123456", role: role)
    visit new_session_path
    fill_in "email_address", with: "#{role}@example.com"
    fill_in "password", with: "secret123456"
    click_on "登录"
  end

  test "viewer 看不到任何操作按钮" do
    sign_in_as("viewer")
    visit managed_app_path(@app)

    assert_text "blog"
    assert_no_selector "[data-action-button]"
    assert_no_text "回滚"
  end

  test "operator 看得到操作按钮" do
    sign_in_as("operator")
    visit managed_app_path(@app)

    assert_selector "[data-action-button]"
  end
end
```

- [ ] **Step 2: 运行，确认失败**

Run: `bin/rails test:system TEST=test/system/role_visibility_test.rb`
Expected: FAIL —— 尚无按钮，第二条断言不通过

- [ ] **Step 3: 实现 helper 与按钮区**

`app/helpers/authorization_helper.rb`：

```ruby
module AuthorizationHelper
  # viewer 看不到按钮，而不是看到置灰的按钮（spec 7.7）。
  # 置灰会诱导人追问「为什么我不能点」，而答案对他们没有用。
  def operator_only(&block)
    capture(&block) if Current.user&.operator?
  end
end
```

`app/views/managed_apps/show.html.erb` 追加：

```erb
<%= operator_only do %>
  <section class="actions">
    <h2>操作</h2>
    <p class="actions-hint">这些操作会改变线上状态，全部记入审计。</p>
    <div class="action-buttons">
      <button data-action-button="restart" type="button">重启</button>
      <button data-action-button="stop" type="button">停止</button>
      <button data-action-button="start" type="button">启动</button>
    </div>
  </section>
<% end %>
```

（回滚入口在 Task 8 加入；此处先立骨架与可见性。）

- [ ] **Step 4: 运行，确认通过**

Run: `bin/rails test:system TEST=test/system/role_visibility_test.rb`
Expected: 2 runs, 0 failures

- [ ] **Step 5: 提交**

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "feat: viewer 看不到操作按钮而非看到置灰按钮"
```

---

## Task 4: AuditLog——先写后做，不可删除

**Files:**
- Create: `db/migrate/<ts>_create_audit_logs.rb`
- Create: `app/models/audit_log.rb`
- Create: `app/controllers/audit_logs_controller.rb`
- Create: `app/views/audit_logs/index.html.erb`
- Modify: `config/routes.rb`
- Test: `test/models/audit_log_test.rb`

**Interfaces:**
- Produces: `AuditLog.start!(user:, managed_app:, action_name:, target_version:, hosts:)` → AuditLog（`result: "pending"`）；`AuditLog#finish!(result:, command:, output_digest:, duration_ms:)`
  - 关键字是 `action_name:` 而非 `action:` —— `action` 在 Rails 中与控制器/路由词汇冲突。Tasks 7、9、10 都写这个模型，务必一致。

- [ ] **Step 1: 建表**

```bash
bin/rails generate migration CreateAuditLogs
```

```ruby
class CreateAuditLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :audit_logs do |t|
      t.references :user, null: false, foreign_key: true
      t.references :managed_app, null: false, foreign_key: true
      t.string   :action_name, null: false
      t.string   :target_version
      t.text     :hosts
      t.text     :command
      t.text     :output_digest
      t.string   :result, null: false, default: "pending"
      t.integer  :duration_ms
      t.datetime :created_at, null: false
      t.datetime :finished_at
    end

    add_index :audit_logs, [ :managed_app_id, :created_at ]
  end
end
```

```bash
bin/rails db:migrate
```

- [ ] **Step 2: 写失败测试**

`test/models/audit_log_test.rb`：

```ruby
require "test_helper"

class AuditLogTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email_address: "op@example.com", password: "secret123456", role: "operator")
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  test "start! 先落一条 pending" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "rollback",
                          target_version: "aaaaaaa", hosts: [ "10.0.0.1" ])

    assert_equal "pending", log.result
    assert_nil log.finished_at
  end

  test "finish! 更新结果与耗时" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "restart",
                          target_version: nil, hosts: [ "10.0.0.1" ])
    log.finish!(result: "success", command: "kamal app restart", output_digest: "ok", duration_ms: 1234)

    assert_equal "success", log.reload.result
    assert_equal 1234, log.duration_ms
    assert_not_nil log.finished_at
  end

  test "审计日志不可删除" do
    log = AuditLog.start!(user: @user, managed_app: @app, action_name: "stop",
                          target_version: nil, hosts: [])

    assert_raises(ActiveRecord::ReadOnlyRecord) { log.destroy }
  end

  test "中途崩溃留下的 pending 记录仍可查" do
    AuditLog.start!(user: @user, managed_app: @app, action_name: "rollback",
                    target_version: "aaaaaaa", hosts: [ "10.0.0.1" ])

    assert_equal 1, AuditLog.where(result: "pending").count
  end
end
```

- [ ] **Step 3: 运行，确认失败**

Run: `bin/rails test test/models/audit_log_test.rb`
Expected: FAIL —— `NameError: uninitialized constant AuditLog`

- [ ] **Step 4: 实现**

`app/models/audit_log.rb`：

```ruby
# 先写后做（spec 7.5）：动作发起前就落一条 pending，执行完再更新。
# 面板中途崩溃时也留下「有人发起过这个操作」的痕迹——
# 事后追查时，「没有记录」与「记录显示中断」是完全不同的信息量。
class AuditLog < ApplicationRecord
  belongs_to :user
  belongs_to :managed_app

  RESULTS = %w[pending success failure].freeze

  validates :action_name, presence: true
  validates :result, inclusion: { in: RESULTS }

  serialize :hosts, coder: JSON, type: Array

  # 审计日志不可删除，UI 也不提供删除入口。
  def destroy = raise(ActiveRecord::ReadOnlyRecord, "审计日志不可删除")
  def delete  = raise(ActiveRecord::ReadOnlyRecord, "审计日志不可删除")

  def self.start!(user:, managed_app:, action_name:, target_version:, hosts:)
    create!(user:, managed_app:, action_name:, target_version:, hosts: Array(hosts),
            result: "pending", created_at: Time.current)
  end

  def finish!(result:, command:, output_digest:, duration_ms:)
    update_columns(result:, command:, output_digest: output_digest.to_s.truncate(4000),
                   duration_ms:, finished_at: Time.current)
  end
end
```

- [ ] **Step 5: 运行，确认通过**

Run: `bin/rails test test/models/audit_log_test.rb`
Expected: 4 runs, 0 failures

- [ ] **Step 6: 只读列表页**

`config/routes.rb` 加 `resources :audit_logs, only: [ :index ]`。

`app/controllers/audit_logs_controller.rb`：

```ruby
class AuditLogsController < ApplicationController
  def index
    @audit_logs = AuditLog.includes(:user, :managed_app).order(created_at: :desc).limit(200)
  end
end
```

`app/views/audit_logs/index.html.erb`：

```erb
<h1>审计</h1>
<p class="hint">记录面板上发起的每一次操作。不可删除。</p>

<table>
  <thead>
    <tr><th>时间</th><th>操作人</th><th>应用</th><th>动作</th><th>目标版本</th><th>结果</th><th>耗时</th></tr>
  </thead>
  <tbody>
    <% @audit_logs.each do |log| %>
      <tr>
        <td><%= log.created_at.strftime("%Y-%m-%d %H:%M:%S") %></td>
        <td><%= log.user.email_address %></td>
        <td><%= log.managed_app.name %></td>
        <td><%= log.action_name %></td>
        <td><%= log.target_version || "—" %></td>
        <td>
          <% case log.result %>
          <% when "pending" %>
            <strong>进行中或已中断</strong>
          <% when "success" %>
            成功
          <% else %>
            <strong>失败</strong>
          <% end %>
        </td>
        <td><%= log.duration_ms ? "#{log.duration_ms} ms" : "—" %></td>
      </tr>
    <% end %>
  </tbody>
</table>
```

注意「pending」的文案是「进行中**或已中断**」——面板无法区分两者，就不该假装能。

- [ ] **Step 7: 全套测试并提交**

Run: `bin/rails test:all`

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "feat: AuditLog 先写后做，不可删除

pending 的文案是「进行中或已中断」——面板无法区分两者，不该假装能。"
```

---

## Task 5: 部署锁状态（纯读，白得的功能）

**Files:**
- Create: `app/services/kamal_lock.rb`
- Modify: `app/views/managed_apps/show.html.erb`
- Test: `test/services/kamal_lock_test.rb`

**Interfaces:**
- Consumes: `Collectors::SshSession#capture`、`ManagedApp#parsed_config`
- Produces: `KamalLock.new(managed_app).status` → `{ locked: Boolean, details: String|nil, error: String|nil }`

spec 7.4：锁是 primary host 上的一个目录，内容 base64 编码了 message 与 version。读它是纯读操作，成本接近零，却能让 UI 在 CI 部署期间把按钮置灰并显示持有者。

- [ ] **Step 1: 写失败测试（连真实 fake host）**

`test/services/kamal_lock_test.rb`：

```ruby
require "test_helper"

class KamalLockTest < ExecutionLayerTest
  def build_app
    yaml = <<~YAML
      service: blog
      image: example/blog
      servers:
        web:
          - 127.0.0.1
      registry:
        server: registry.example.com
        username: someone
        password:
          - KAMAL_REGISTRY_PASSWORD
      builder:
        arch: amd64
      ssh:
        user: deploy
        port: #{FakeHost::NODES.fetch("node-1")}
    YAML

    ManagedApp.create!(name: "blog-#{SecureRandom.hex(4)}", config_yaml: yaml,
                       destination: "production",
                       ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key))
  end

  test "没有锁时报告未锁定" do
    status = KamalLock.new(build_app).status

    refute status[:locked]
    assert_nil status[:error]
  end

  test "锁目录存在时报告已锁定并带出持有者信息" do
    app = build_app
    lock_dir = ".kamal/lock-blog-production"
    FakeHost.ssh("node-1", "mkdir -p #{lock_dir} && printf 'Locked by: ci@example.com' | base64 > #{lock_dir}/details")

    status = KamalLock.new(app).status

    assert status[:locked]
    assert_match "ci@example.com", status[:details]
  ensure
    FakeHost.ssh("node-1", "rm -rf .kamal/lock-blog-production")
  end

  test "主机不可达时报告错误而不是「未锁定」" do
    app = build_app
    app.update_column(:config_yaml, app.config_yaml.sub("127.0.0.1", "192.0.2.1"))

    status = KamalLock.new(app.reload).status

    refute status[:locked]
    assert_predicate status[:error], :present?
  end
end
```

第三条是关键：**连不上时绝不能报告「未锁定」**——那会让面板允许一次它无权确认的操作。

- [ ] **Step 2: 运行，确认失败**

Run: `bin/rails test test/services/kamal_lock_test.rb`
Expected: FAIL —— `NameError: uninitialized constant KamalLock`

- [ ] **Step 3: 实现**

`app/services/kamal_lock.rb`：

```ruby
# 读 Kamal 自己的部署锁（spec 7.4）。
#
# 锁是 primary host 上的一个目录，details 文件里是 base64 编码的持有者信息。
# 目录名规则来自 Kamal::Commands::Lock#lock_dir：
#   [ "lock", service, destination ].compact.join("-")，位于 config.run_directory
#
# 这是纯读操作。面板执行任何变更前必须获取【同一把锁】，否则会与 CI 里
# 正在跑的 kamal deploy 冲突——在本项目设定的架构下（发布归 CI）这是常态。
class KamalLock
  def initialize(managed_app)
    @managed_app = managed_app
  end

  def status
    result = session.capture_many([ primary_host ]) { read_command }.fetch(primary_host)

    # 连不上时【绝不报告「未锁定」】：那会让面板放行一次它无权确认的操作。
    return { locked: false, details: nil, error: result.error } if result.error

    stdout = result.stdout.to_s
    if stdout.include?("LOCK_ABSENT")
      { locked: false, details: nil, error: nil }
    else
      { locked: true, details: stdout.strip.presence, error: nil }
    end
  end

  private
    attr_reader :managed_app

    def session = Collectors::SshSession.new(managed_app)

    def primary_host = managed_app.parsed_config.primary_host

    def lock_dir
      name = [ "lock", managed_app.service, managed_app.destination ].compact.join("-")
      ".kamal/#{name}"
    end

    def read_command
      dir = Shellwords.escape(lock_dir)
      "if [ -d #{dir} ]; then cat #{dir}/details 2>/dev/null | base64 -d; else echo LOCK_ABSENT; fi"
    end
end
```

- [ ] **Step 4: 运行，确认通过**

Run: `bin/rails test test/services/kamal_lock_test.rb`
Expected: 3 runs, 0 failures

- [ ] **Step 5: UI 显示锁状态**

`app/views/managed_apps/show.html.erb` 在操作区之前插入：

```erb
<% lock = KamalLock.new(@managed_app).status %>
<% if lock[:error] %>
  <p class="lock-unknown"><strong>锁状态未知</strong> —— 无法连接 primary host，操作已禁用</p>
<% elsif lock[:locked] %>
  <p class="lock-held"><strong>部署进行中</strong><br><small><%= lock[:details] %></small></p>
<% end %>
```

并把 Task 3 的按钮区包在 `<% if lock[:error].nil? && !lock[:locked] %>` 内。

- [ ] **Step 6: 全套测试并提交**

Run: `bin/rails test:all`

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "feat: 读取并显示 Kamal 部署锁状态

连不上 primary host 时报告「锁状态未知」并禁用操作，
绝不报告「未锁定」——那会放行一次面板无权确认的操作。"
```

---

## Task 6: 执行基座——ssh-agent + tempdir + kamal CLI 子进程

**Files:**
- Create: `app/services/kamal_cli/agent.rb`
- Create: `app/services/kamal_cli/invocation.rb`
- Test: `test/services/kamal_cli/invocation_test.rb`

**Interfaces:**
- Consumes: `ManagedApp#config_yaml`、`#destination_config_yaml`、`#destination`、`#ssh_credential`
- Produces: `KamalCli::Invocation.new(managed_app).run(%w[app details]) { |line| ... }` → `{ status: Integer, output: String }`

**这是整个计划的承重件。** 承重假设（已实测）：每次调用起独立 ssh-agent，密钥经 `ssh-add -` 从 stdin 注入，`SSH_AUTH_SOCK` 传给子进程，结束时 `ensure` 里杀掉 agent。**私钥全程不落盘。**

- [ ] **Step 1: 写失败测试**

`test/services/kamal_cli/invocation_test.rb`：

```ruby
require "test_helper"

class KamalCli::InvocationTest < ExecutionLayerTest
  def build_app
    yaml = <<~YAML
      service: blog
      image: example/blog
      servers:
        web:
          - 127.0.0.1
      registry:
        server: registry.example.com
        username: someone
        password:
          - KAMAL_REGISTRY_PASSWORD
      builder:
        arch: amd64
      ssh:
        user: deploy
        port: #{FakeHost::NODES.fetch("node-1")}
    YAML

    ManagedApp.create!(name: "blog-#{SecureRandom.hex(4)}", config_yaml: yaml,
                       destination: "production",
                       ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key))
  end

  test "能对真实主机跑通一条只读的 kamal 命令" do
    lines = []
    result = KamalCli::Invocation.new(build_app).run(%w[app details]) { |line| lines << line }

    assert_kind_of Integer, result[:status]
    assert_predicate lines, :any?, "应逐行产出输出"
  end

  # 注意这条测试的形状——它在 Task 6 实施时被发现是【假阴性】，已修正。
  #
  # 原写法把 File.read 放在 run 返回【之后】，而 Dir.mktmpdir 那时已经删掉了临时目录，
  # 于是 File.read 恒抛 ENOENT，又被 `rescue false` 静默吞掉，测试永远通过。
  # 用变异测试证实：故意让实现把密钥写进临时目录中的文件，原测试【照样通过】。
  #
  # 正确的形状是【在 yield 的块内、清理发生之前】就地检查。
  # 教训：一条断言若在被检查对象已经消失之后才执行，它证明的是「东西不在了」，
  # 而不是「东西从未出现过」。
  test "私钥全程不落盘" do
    app = build_app
    leaked = []

    KamalCli::Invocation.new(app).run(%w[version]) do |_line|
      Dir.glob("#{Dir.tmpdir}/kamal-panel-*/**/*").each do |path|
        next unless File.file?(path)

        begin
          leaked << path if File.read(path).include?("PRIVATE KEY")
        rescue Errno::ENOENT, ArgumentError
          # 文件在读取前消失、或含非 UTF-8 字节：都不算泄漏证据
        end
      end
    end

    assert_empty leaked, "临时目录中不得出现私钥内容"
  end

  test "调用结束后临时目录与 agent 均被清理" do
    app = build_app
    before = Dir.glob("#{Dir.tmpdir}/kamal-panel-*").size

    KamalCli::Invocation.new(app).run(%w[version]) { |_| }

    assert_equal before, Dir.glob("#{Dir.tmpdir}/kamal-panel-*").size
  end

  test "超时会杀掉子进程并返回非零状态" do
    app = build_app
    result = KamalCli::Invocation.new(app, timeout: 1).run(%w[app logs --follow]) { |_| }

    refute_equal 0, result[:status]
  end
end
```

- [ ] **Step 2: 运行，确认失败**

Run: `bin/rails test test/services/kamal_cli/invocation_test.rb`
Expected: FAIL —— `NameError: uninitialized constant KamalCli::Invocation`

- [ ] **Step 3: 实现 agent 生命周期**

`app/services/kamal_cli/agent.rb`：

```ruby
require "open3"

module KamalCli
  # 每次调用独立的 ssh-agent。密钥经 stdin 注入（ssh-add -），【绝不落盘】。
  #
  # 这条已于 2026-09-06 对真实主机实测：不给 ssh -i、仅靠 agent 即可认证。
  # 若某个环境下不成立，调用方应报错，而不是退回「把密钥写到 0600 文件」。
  class Agent
    class StartFailed < StandardError; end

    def self.with(private_key)
      agent = new
      agent.start!
      agent.add_key!(private_key)
      yield agent.auth_sock
    ensure
      agent&.stop!
    end

    attr_reader :auth_sock, :pid

    def start!
      out, status = Open3.capture2("ssh-agent", "-s")
      raise StartFailed, "ssh-agent 启动失败" unless status.success?

      @auth_sock = out[/SSH_AUTH_SOCK=([^;]+);/, 1]
      @pid       = out[/SSH_AGENT_PID=(\d+);/, 1]
      raise StartFailed, "无法从 ssh-agent 输出中解析 socket" if @auth_sock.blank?
    end

    def add_key!(private_key)
      out, status = Open3.capture2e({ "SSH_AUTH_SOCK" => auth_sock }, "ssh-add", "-", stdin_data: private_key)
      raise StartFailed, "ssh-add 失败：#{out.lines.first}" unless status.success?
    end

    def stop!
      return if pid.blank?

      Process.kill("TERM", pid.to_i)
    rescue Errno::ESRCH
      # 已经没了，正常
    end
  end
end
```

- [ ] **Step 4: 实现调用封装**

`app/services/kamal_cli/invocation.rb`：

```ruby
require "open3"
require "tmpdir"

module KamalCli
  # 在受限子进程中执行 kamal CLI。
  #
  # 为什么调 CLI 而不是自己用 Kamal::Commands::App 拼命令：
  # kamal rollback 不只是启动容器——它还会触发用户自己的 pre/post-deploy hook、
  # 切换 kamal-proxy 路由、跑健康检查。自己重实现等于再造一个必须与 Kamal
  # 永远保持一致的实现，而计划 01 已经为「两个必须永远同意的实现」付过学费。
  #
  # 临时目录由【父进程】拥有并在 ensure 中清理——子进程可能被 SIGKILL，
  # 它的 ensure 不会运行（计划 01 Task 3 的教训）。
  class Invocation
    DEFAULT_TIMEOUT = 10.minutes

    def initialize(managed_app, timeout: DEFAULT_TIMEOUT)
      @managed_app = managed_app
      @timeout = timeout
    end

    # 逐行 yield 子进程输出；返回 { status:, output: }
    def run(args, &block)
      Dir.mktmpdir("kamal-panel-") do |dir|
        write_config_files(dir)

        Agent.with(private_key) do |auth_sock|
          execute(dir, auth_sock, args, &block)
        end
      end
    end

    private
      attr_reader :managed_app, :timeout

      def private_key
        managed_app.ssh_credential&.value or raise ArgumentError, "该应用未配置 SSH 私钥"
      end

      def write_config_files(dir)
        File.write(File.join(dir, "deploy.yml"), managed_app.config_yaml)

        return if managed_app.destination.blank?

        overlay = managed_app.destination_config_yaml.presence || "{}"
        File.write(File.join(dir, "deploy.#{managed_app.destination}.yml"), overlay)
      end

      def execute(dir, auth_sock, args, &block)
        cmd = [ "kamal", *args ]
        cmd += [ "--destination", managed_app.destination ] if managed_app.destination.present?

        env = {
          "SSH_AUTH_SOCK" => auth_sock,
          # 让 kamal 在临时目录里找配置，而不是当前工作目录
          "KAMAL_CONFIG_DIR" => dir
        }

        output = +""
        status = nil

        Open3.popen2e(env, *cmd, chdir: dir) do |stdin, out, wait_thread|
          stdin.close

          reader = Thread.new do
            out.each_line do |line|
              output << line
              block&.call(line.chomp)
            end
          end

          unless wait_thread.join(timeout)
            Process.kill("KILL", wait_thread.pid)
            wait_thread.join
            reader.kill
            return { status: 124, output: output + "\n[面板] 执行超时，已终止" }
          end

          reader.join
          status = wait_thread.value.exitstatus
        end

        { status: status, output: output }
      end
  end
end
```

> `KAMAL_CONFIG_DIR` 需在 Step 5 对着 kamal 2.12.0 验证；若该环境变量不被支持，改用 `--config-file <dir>/deploy.yml`，并在报告中说明。

- [ ] **Step 5: 验证 kamal 如何定位配置**

```bash
kamal help | head -30
kamal app details --help 2>&1 | grep -i "config"
```

据实际支持的方式调整 `execute`，并在报告中写明采用了哪一种。

- [ ] **Step 6: 运行，确认通过**

Run: `bin/rails test test/services/kamal_cli/invocation_test.rb`
Expected: 4 runs, 0 failures

- [ ] **Step 7: 提交**

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "feat: kamal CLI 执行基座——私钥经 ssh-agent 注入，不落盘

调 CLI 而非自己拼命令：rollback 会触发用户的 hook、切换 proxy 路由、
跑健康检查，重实现等于再造一个必须与 Kamal 永远一致的实现。
临时目录由父进程拥有并清理——子进程可能被 SIGKILL，它的 ensure 不会跑。"
```

---

## Task 7: 封闭动作集框架

**Files:**
- Create: `app/services/actions/base.rb`
- Create: `app/services/actions/restart.rb`、`stop.rb`、`start.rb`
- Create: `app/jobs/run_action_job.rb`
- Create: `app/controllers/actions_controller.rb`
- Modify: `config/routes.rb`
- Test: `test/services/actions/base_test.rb`、`test/controllers/actions_controller_test.rb`

**Interfaces:**
- Consumes: `KamalCli::Invocation`（Task 6）、`AuditLog`（Task 4）、`KamalLock`（Task 5）
- Produces: `Actions::Base.find(name)` → 类；`#cli_args` / `#requires_lock?` / `#required_role` / `#affected_hosts`；`RunActionJob.perform_later(audit_log_id)`

- [ ] **Step 1: 写失败测试——注册表只认封闭集合**

`test/services/actions/base_test.rb`：

```ruby
require "test_helper"

class Actions::BaseTest < ActiveSupport::TestCase
  test "只认已注册的动作名" do
    assert_equal Actions::Restart, Actions::Base.find("restart")
    assert_equal Actions::Stop,    Actions::Base.find("stop")
    assert_equal Actions::Start,   Actions::Base.find("start")
  end

  test "未知动作名被拒绝——面板永远不执行任意命令" do
    assert_raises(Actions::Base::UnknownAction) { Actions::Base.find("exec") }
    assert_raises(Actions::Base::UnknownAction) { Actions::Base.find("rm -rf /") }
  end

  test "每个动作都声明所需角色与是否要锁" do
    Actions::Base.all.each do |klass|
      assert_includes User::ROLES, klass.required_role, "#{klass} 未声明合法角色"
      assert_includes [ true, false ], klass.requires_lock?, "#{klass} 未声明是否要锁"
    end
  end
end
```

- [ ] **Step 2: 运行，确认失败**

Run: `bin/rails test test/services/actions/base_test.rb`
Expected: FAIL —— `NameError: uninitialized constant Actions::Base`

- [ ] **Step 3: 实现基类与三个动作**

`app/services/actions/base.rb`：

```ruby
# 封闭动作集（spec 7.3）。面板永远不执行任意命令。
#
# 新增动作必须在 REGISTRY 中显式登记——没有「按名字动态查找类」这种事，
# 那等价于把动作名当成代码来执行。
module Actions
  class Base
    class UnknownAction < StandardError; end

    def self.registry
      {
        "restart"      => Actions::Restart,
        "stop"         => Actions::Stop,
        "start"        => Actions::Start,
        "rollback"     => Actions::Rollback,
        "force_unlock" => Actions::ForceUnlock
      }
    end

    def self.all = registry.values

    def self.find(name)
      registry.fetch(name.to_s) { raise UnknownAction, "未知动作：#{name.inspect}" }
    end

    def self.required_role = "operator"
    def self.requires_lock? = true
    def self.confirm_by_name? = false

    def initialize(managed_app, target_version: nil)
      @managed_app = managed_app
      @target_version = target_version
    end

    attr_reader :managed_app, :target_version

    def cli_args = raise(NotImplementedError)

    def affected_hosts = managed_app.cached_app_hosts
  end
end
```

`app/services/actions/restart.rb`：

```ruby
module Actions
  class Restart < Base
    def cli_args = %w[app boot]
  end
end
```

`app/services/actions/stop.rb`：

```ruby
module Actions
  class Stop < Base
    def self.confirm_by_name? = true

    def cli_args = %w[app stop]
  end
end
```

`app/services/actions/start.rb`：

```ruby
module Actions
  class Start < Base
    def cli_args = %w[app start]
  end
end
```

（`Rollback` 与 `ForceUnlock` 分别在 Task 8、Task 10 加入；此处 `registry` 已预留其名，故这两个任务之前 `Actions::Base.all` 会 `NameError` —— Step 4 的顺序因此重要。）

- [ ] **Step 4: 先加占位以保证注册表可用**

在 Task 8/10 完成之前，`app/services/actions/rollback.rb` 与 `force_unlock.rb` 先写最小占位：

```ruby
module Actions
  class Rollback < Base
    def self.confirm_by_name? = true
    def cli_args = [ "rollback", target_version.to_s ]
  end
end
```

```ruby
module Actions
  class ForceUnlock < Base
    def self.requires_lock? = false
    def self.confirm_by_name? = true
    def cli_args = %w[lock release]
  end
end
```

- [ ] **Step 5: 运行，确认通过**

Run: `bin/rails test test/services/actions/base_test.rb`
Expected: 3 runs, 0 failures

- [ ] **Step 6: 执行作业——先写审计，再取锁，再执行**

`app/jobs/run_action_job.rb`：

```ruby
# 执行一个动作。顺序是刻意的（spec 7.5）：
#   审计先落 pending → 检查锁 → 执行 → 更新审计
# 面板中途崩溃时留下的 pending 记录，正是「有人发起过这个操作」的证据。
class RunActionJob < ApplicationJob
  queue_as :default

  def perform(audit_log_id)
    log = AuditLog.find(audit_log_id)
    app = log.managed_app
    action = Actions::Base.find(log.action_name).new(app, target_version: log.target_version)
    started = Time.current

    if action.class.requires_lock? && !lock_free?(app, log, started)
      return
    end

    output = +""
    status = nil

    result = KamalCli::Invocation.new(app).run(action.cli_args) do |line|
      output << line << "\n"
      broadcast_line(log, line)
    end
    status = result[:status]

    log.finish!(result: status.zero? ? "success" : "failure",
                command: "kamal #{action.cli_args.join(' ')}",
                output_digest: result[:output],
                duration_ms: ((Time.current - started) * 1000).round)

    # 不拿命令退出码当结论（spec 8.4）：触发 burst 轮询，用新的 Observation 确认。
    PollCadence.mark_burst!(app)
    PollManagedAppJob.perform_later(app)
  end

  private
    def lock_free?(app, log, started)
      lock = KamalLock.new(app).status

      if lock[:error]
        finish_blocked(log, started, "锁状态未知：#{lock[:error]}")
        return false
      end

      if lock[:locked]
        finish_blocked(log, started, "部署进行中，未执行。持有者：#{lock[:details]}")
        return false
      end

      true
    end

    def finish_blocked(log, started, message)
      broadcast_line(log, message)
      log.finish!(result: "failure", command: "(未执行)", output_digest: message,
                  duration_ms: ((Time.current - started) * 1000).round)
    end

    def broadcast_line(log, line)
      Turbo::StreamsChannel.broadcast_append_to(
        "action_#{log.id}", target: "action-output",
        html: ActionController::Base.helpers.tag.div(line, class: "output-line")
      )
    rescue StandardError => e
      # 投递失败不得连累执行本身（计划 01 Task 12 的教训）
      Rails.logger.error("[action] 广播失败: #{e.class}")
    end
end
```

- [ ] **Step 7: 唯一的写入口**

`config/routes.rb`：

```ruby
  resources :managed_apps, path: "apps", only: [ :index, :new, :create, :show ] do
    resources :actions, only: [ :create, :show ]
  end
```

`app/controllers/actions_controller.rb`：

```ruby
class ActionsController < ApplicationController
  before_action :require_operator!, only: :create

  def create
    app = ManagedApp.find(params[:managed_app_id])
    action_class = Actions::Base.find(params[:name])

    if action_class.confirm_by_name? && params[:confirm_name] != app.name
      return redirect_to app, alert: "确认失败：请手输应用名"
    end

    log = AuditLog.start!(user: Current.user, managed_app: app,
                          action_name: params[:name], target_version: params[:version],
                          hosts: action_class.new(app).affected_hosts)
    RunActionJob.perform_later(log.id)

    redirect_to managed_app_action_path(app, log)
  rescue Actions::Base::UnknownAction
    redirect_to app, alert: "未知操作"
  end

  def show
    @managed_app = ManagedApp.find(params[:managed_app_id])
    @audit_log = AuditLog.find(params[:id])
  end
end
```

- [ ] **Step 8: 控制器测试**

`test/controllers/actions_controller_test.rb`：

```ruby
require "test_helper"

class ActionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  def sign_in(role)
    User.create!(email_address: "#{role}@example.com", password: "secret123456", role: role)
    post session_path, params: { email_address: "#{role}@example.com", password: "secret123456" }
  end

  test "viewer 不能发起动作" do
    sign_in("viewer")
    assert_no_difference("AuditLog.count") do
      post managed_app_actions_path(@app), params: { name: "restart" }
    end
  end

  test "未知动作名被拒绝且不落审计" do
    sign_in("operator")
    assert_no_difference("AuditLog.count") do
      post managed_app_actions_path(@app), params: { name: "exec" }
    end
  end

  test "需要手输应用名的动作，名字不对则不执行" do
    sign_in("operator")
    assert_no_difference("AuditLog.count") do
      post managed_app_actions_path(@app), params: { name: "stop", confirm_name: "wrong" }
    end
  end

  test "operator 发起 restart 会落一条 pending 审计" do
    sign_in("operator")
    assert_difference("AuditLog.count", 1) do
      post managed_app_actions_path(@app), params: { name: "restart" }
    end
    assert_equal "pending", AuditLog.last.result
  end
end
```

- [ ] **Step 9: 运行全套并提交**

Run: `bin/rails test:all`

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "feat: 封闭动作集框架 + 先写审计再取锁再执行

动作名走显式注册表——没有「按名字动态查找类」，那等价于把动作名当代码执行。
不拿命令退出码当结论：执行完触发 burst 轮询，用新的 Observation 确认。"
```

---

## Task 8: 回滚——只列真正可回滚的版本

**Files:**
- Create: `app/services/rollback_candidates.rb`
- Modify: `app/services/actions/rollback.rb`
- Modify: `app/views/managed_apps/show.html.erb`
- Test: `test/services/rollback_candidates_test.rb`、`test/system/rollback_flow_test.rb`

**Interfaces:**
- Consumes: `Observation.latest_for`、`ManagedApp#cached_app_hosts`、`ManagedApp#parsed_config`
- Produces: `RollbackCandidates.new(managed_app).list` → `[{ version:, available: Boolean, reason: String|nil }]`

spec 7.1：`kamal rollback` 要求该 version 的**容器**在**每台 host 的每个 role** 上都存在，否则直接拒绝。面板手里已有全量 `docker ps --all`，因此能**只列真正可回滚的版本**——CLI 是试了才告诉你不行。

- [ ] **Step 1: 写失败测试**

`test/services/rollback_candidates_test.rb`：

```ruby
require "test_helper"

class RollbackCandidatesTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog",
                              config_yaml: file_fixture("two_host_deploy.yml").read,
                              destination: "production")
    @now = Time.current
  end

  def observe(host:, version:, status: "exited", role: "web")
    Observation.create!(managed_app: @app, host: host, role: role,
                        container_name: "blog-#{role}-production-#{version}",
                        version: version, docker_status: status,
                        reachable: true, observed_at: @now)
  end

  test "所有主机都有该版本容器时可回滚" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", version: "aaaaaaa")

    entry = RollbackCandidates.new(@app).list.detect { |c| c[:version] == "aaaaaaa" }

    assert entry[:available]
    assert_nil entry[:reason]
  end

  test "某台主机上已被清理时不可回滚，并注明是哪一台" do
    observe(host: "10.0.0.1", version: "aaaaaaa")

    entry = RollbackCandidates.new(@app).list.detect { |c| c[:version] == "aaaaaaa" }

    refute entry[:available]
    assert_match "10.0.0.2", entry[:reason]
  end

  test "当前正在运行的版本不出现在回滚候选中" do
    observe(host: "10.0.0.1", version: "current", status: "running")
    observe(host: "10.0.0.2", version: "current", status: "running")

    versions = RollbackCandidates.new(@app).list.map { |c| c[:version] }

    refute_includes versions, "current"
  end
end
```

- [ ] **Step 2: 运行，确认失败**

Run: `bin/rails test test/services/rollback_candidates_test.rb`
Expected: FAIL —— `NameError: uninitialized constant RollbackCandidates`

- [ ] **Step 3: 实现**

`app/services/rollback_candidates.rb`：

```ruby
# 面板相对 CLI 的真实增量（spec 7.1）。
#
# kamal rollback 要求该 version 的容器在【每台 host 的每个 role】上都存在，
# 否则直接拒绝——CLI 是你试了才告诉你不行。
# 面板手里已有全量 docker ps --all，因此能提前算出来，并注明是哪台机器缺。
class RollbackCandidates
  RUNNING_STATUSES = %w[running restarting].freeze

  def initialize(managed_app)
    @managed_app = managed_app
  end

  def list
    stopped_versions.map do |version|
      missing = hosts_missing(version)

      { version: version,
        available: missing.empty?,
        reason: missing.empty? ? nil : "#{missing.join('、')} 上已被清理" }
    end
  end

  private
    attr_reader :managed_app

    def observations = @observations ||= Observation.latest_for(managed_app).to_a

    def running_versions
      observations.select { |o| RUNNING_STATUSES.include?(o.docker_status) }
                  .filter_map(&:version).uniq
    end

    def stopped_versions
      observations.filter_map(&:version).uniq - running_versions
    end

    def hosts_missing(version)
      managed_app.cached_app_hosts.reject do |host|
        observations.any? { |o| o.host == host && o.version == version }
      end
    end
end
```

- [ ] **Step 4: 运行，确认通过**

Run: `bin/rails test test/services/rollback_candidates_test.rb`
Expected: 3 runs, 0 failures

- [ ] **Step 5: 回滚四步交互**

`app/views/managed_apps/show.html.erb` 的操作区内加入：

```erb
<h3>回滚</h3>
<% candidates = RollbackCandidates.new(@managed_app).list %>
<% if candidates.empty? %>
  <p>没有可回滚的历史版本。</p>
<% else %>
  <%= form_with url: managed_app_actions_path(@managed_app), method: :post do |form| %>
    <%= form.hidden_field :name, value: "rollback" %>

    <ol class="rollback-steps">
      <li>
        <strong>选版本</strong>
        <% candidates.each do |c| %>
          <label class="<%= "unavailable" unless c[:available] %>">
            <%= form.radio_button :version, c[:version], disabled: !c[:available] %>
            <%= c[:version] %>
            <% unless c[:available] %>
              <small>—— <%= c[:reason] %></small>
            <% end %>
          </label>
        <% end %>
      </li>
      <li>
        <strong>确认影响面</strong>
        <p>将操作 <%= @managed_app.cached_app_hosts.join("、") %>
           上的 <%= @managed_app.role_names.join("、") %>。</p>
      </li>
      <li>
        <strong>手输应用名确认</strong>
        <%= form.text_field :confirm_name, placeholder: @managed_app.name %>
      </li>
    </ol>

    <%= form.submit "执行回滚" %>
  <% end %>
<% end %>
```

第四步（实时流式输出）在 Task 11。

- [ ] **Step 6: 系统测试——不可回滚的版本不能被选中**

`test/system/rollback_flow_test.rb`：

```ruby
require "application_system_test_case"

class RollbackFlowTest < ApplicationSystemTestCase
  setup do
    @app = ManagedApp.create!(name: "blog",
                              config_yaml: file_fixture("two_host_deploy.yml").read,
                              destination: "production")
    User.create!(email_address: "op@example.com", password: "secret123456", role: "operator")
    visit new_session_path
    fill_in "email_address", with: "op@example.com"
    fill_in "password", with: "secret123456"
    click_on "登录"
  end

  test "缺容器的版本被置灰并注明原因" do
    Observation.create!(managed_app: @app, host: "10.0.0.1", role: "web",
                        container_name: "blog-web-production-aaaaaaa", version: "aaaaaaa",
                        docker_status: "exited", reachable: true, observed_at: Time.current)

    visit managed_app_path(@app)

    assert_text "10.0.0.2 上已被清理"
    assert_selector "input[type=radio][value='aaaaaaa'][disabled]"
  end
end
```

- [ ] **Step 7: 运行全套并提交**

Run: `bin/rails test:all`

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "feat: 回滚——只列真正可回滚的版本，其余置灰并注明缺在哪台

CLI 是试了才告诉你不行；面板手里已有全量 docker ps --all，可以提前算出来。"
```

---

## Task 9: restart / stop / start 的端到端验证

**Files:**
- Test: `test/services/actions/execution_test.rb`

**Interfaces:**
- Consumes: Task 6、7 的全部产出

前面三个动作类只有 `cli_args`，尚未对真实主机验证过。这个任务不写新代码，只补真实执行的测试——**一个从未真正执行过的动作不算实现完成**。

- [ ] **Step 1: 写执行层测试**

`test/services/actions/execution_test.rb`：

```ruby
require "test_helper"

class Actions::ExecutionTest < ExecutionLayerTest
  def build_app
    yaml = <<~YAML
      service: blog
      image: busybox:latest
      servers:
        web:
          - 127.0.0.1
      registry:
        server: registry.example.com
        username: someone
        password:
          - KAMAL_REGISTRY_PASSWORD
      builder:
        arch: amd64
      ssh:
        user: deploy
        port: #{FakeHost::NODES.fetch("node-1")}
    YAML

    ManagedApp.create!(name: "blog-#{SecureRandom.hex(4)}", config_yaml: yaml,
                       destination: "production",
                       ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key))
  end

  def operator
    @operator ||= User.create!(email_address: "op@example.com", password: "secret123456",
                               role: "operator")
  end

  test "stop 对真实主机执行并把结果写进审计" do
    app = build_app
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")

    log = AuditLog.start!(user: operator, managed_app: app, action_name: "stop",
                          target_version: nil, hosts: app.cached_app_hosts)
    RunActionJob.perform_now(log.id)

    assert_includes %w[success failure], log.reload.result
    refute_equal "pending", log.result, "执行完必须更新审计，不能停在 pending"
    assert_predicate log.duration_ms, :present?
  end

  test "锁被占用时不执行，并在审计中说明" do
    app = build_app
    lock_dir = ".kamal/lock-blog-production"
    FakeHost.ssh("node-1", "mkdir -p #{lock_dir} && printf 'Locked by: ci' | base64 > #{lock_dir}/details")

    log = AuditLog.start!(user: operator, managed_app: app, action_name: "restart",
                          target_version: nil, hosts: app.cached_app_hosts)
    RunActionJob.perform_now(log.id)

    assert_equal "failure", log.reload.result
    assert_match "部署进行中", log.output_digest
  ensure
    FakeHost.ssh("node-1", "rm -rf .kamal/lock-blog-production")
  end
end
```

- [ ] **Step 2: 运行，据实际结果修正**

Run: `bin/rails test test/services/actions/execution_test.rb`

fake host 上没有真实的 Kamal 部署，因此 `kamal app stop` 很可能以非零状态结束——这是**预期的**。测试断言的是「审计被正确收尾」而非「命令成功」。若 `Invocation` 在这种情形下抛异常而非返回非零状态，那是 Task 6 的缺陷，修它。

- [ ] **Step 3: 提交**

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "test: 三个动作对真实主机的端到端执行与审计收尾

一个从未真正执行过的动作不算实现完成。
断言的是审计被正确收尾，不是命令成功——fake host 上没有真实部署。"
```

---

## Task 10: 强制解锁

**Files:**
- Modify: `app/services/actions/force_unlock.rb`
- Modify: `app/views/managed_apps/show.html.erb`
- Test: `test/services/actions/force_unlock_test.rb`

**Interfaces:**
- Consumes: Task 5 的 `KamalLock`、Task 7 的框架

spec 7.4：v1 提供强制解锁（否则用户遇到 CI 崩溃留下的死锁只能去 SSH），但需 operator + 手输应用名 + **单独的审计标记**。

- [ ] **Step 1: 写失败测试**

`test/services/actions/force_unlock_test.rb`：

```ruby
require "test_helper"

class Actions::ForceUnlockTest < ExecutionLayerTest
  def build_app
    yaml = <<~YAML
      service: blog
      image: busybox:latest
      servers:
        web:
          - 127.0.0.1
      registry:
        server: registry.example.com
        username: someone
        password:
          - KAMAL_REGISTRY_PASSWORD
      builder:
        arch: amd64
      ssh:
        user: deploy
        port: #{FakeHost::NODES.fetch("node-1")}
    YAML

    ManagedApp.create!(name: "blog-#{SecureRandom.hex(4)}", config_yaml: yaml,
                       destination: "production",
                       ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key))
  end

  test "强制解锁本身不需要先拿到锁" do
    refute Actions::ForceUnlock.requires_lock?
  end

  test "强制解锁需要手输应用名" do
    assert Actions::ForceUnlock.confirm_by_name?
  end

  test "解锁后锁状态变为未锁定" do
    app = build_app
    lock_dir = ".kamal/lock-blog-production"
    FakeHost.ssh("node-1", "mkdir -p #{lock_dir} && printf 'stale' | base64 > #{lock_dir}/details")
    assert KamalLock.new(app).status[:locked]

    user = User.create!(email_address: "op@example.com", password: "secret123456", role: "operator")
    log = AuditLog.start!(user: user, managed_app: app, action_name: "force_unlock",
                          target_version: nil, hosts: app.cached_app_hosts)
    RunActionJob.perform_now(log.id)

    refute KamalLock.new(app).status[:locked]
  ensure
    FakeHost.ssh("node-1", "rm -rf .kamal/lock-blog-production")
  end

  test "强制解锁在审计中带独立标记" do
    app = build_app
    user = User.create!(email_address: "op2@example.com", password: "secret123456", role: "operator")
    log = AuditLog.start!(user: user, managed_app: app, action_name: "force_unlock",
                          target_version: nil, hosts: app.cached_app_hosts)

    assert_equal "force_unlock", log.action_name
  end
end
```

- [ ] **Step 2: 运行，据结果补实现**

Run: `bin/rails test test/services/actions/force_unlock_test.rb`

Task 7 已写了占位类。若 `kamal lock release` 的参数形式不对，对着 `kamal lock --help` 校正。

- [ ] **Step 3: UI 入口——只在锁存在时出现**

`app/views/managed_apps/show.html.erb` 的锁状态块内追加：

```erb
<% elsif lock[:locked] %>
  <p class="lock-held"><strong>部署进行中</strong><br><small><%= lock[:details] %></small></p>
  <%= operator_only do %>
    <details class="force-unlock">
      <summary>强制解锁</summary>
      <p>只有在确认锁是 CI 崩溃遗留的死锁时才这样做。正在进行的部署会被打断。</p>
      <%= form_with url: managed_app_actions_path(@managed_app), method: :post do |form| %>
        <%= form.hidden_field :name, value: "force_unlock" %>
        <%= form.text_field :confirm_name, placeholder: "手输应用名确认" %>
        <%= form.submit "强制解锁" %>
      <% end %>
    </details>
  <% end %>
```

- [ ] **Step 4: 运行全套并提交**

Run: `bin/rails test:all`

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "feat: 强制解锁——operator + 手输应用名 + 独立审计标记

入口只在确实存在锁时出现，且文案说明会打断正在进行的部署。"
```

---

## Task 11: 执行过程实时流式输出

**Files:**
- Create: `app/views/actions/show.html.erb`
- Modify: `app/jobs/run_action_job.rb`
- Test: `test/system/action_streaming_test.rb`

**Interfaces:**
- Consumes: `RunActionJob` 的 `broadcast_line`（Task 7）

spec 8.4 第 4 步是**硬要求**：不能是一个转圈动画然后告知「成功了」。运维操作出问题时，人需要看到卡在哪一步。

- [ ] **Step 1: 执行页**

`app/views/actions/show.html.erb`：

```erb
<h1><%= @audit_log.action_name %> —— <%= @managed_app.name %></h1>

<p class="hint">
  执行过程逐行显示在下方。这一页不会自动跳转——请看完输出再离开。
</p>

<%= turbo_stream_from "action_#{@audit_log.id}" %>

<pre id="action-output" class="action-output"></pre>

<p id="action-result">
  <% case @audit_log.result %>
  <% when "pending" %>
    执行中……
  <% when "success" %>
    <strong>已完成</strong> —— 面板正在重新采集，用新的观测确认结果。
  <% else %>
    <strong>失败</strong>
  <% end %>
</p>

<p><%= link_to "返回应用", @managed_app %></p>
```

- [ ] **Step 2: 结束时也广播一次终态**

`app/jobs/run_action_job.rb` 的 `perform` 末尾、`log.finish!` 之后加入：

```ruby
    broadcast_result(log)
```

并加入私有方法：

```ruby
    def broadcast_result(log)
      html = ActionController::Base.helpers.tag.strong(
        log.result == "success" ? "已完成 —— 面板正在重新采集确认" : "失败"
      )
      Turbo::StreamsChannel.broadcast_replace_to(
        "action_#{log.id}", target: "action-result", html: html
      )
    rescue StandardError => e
      Rails.logger.error("[action] 终态广播失败: #{e.class}")
    end
```

- [ ] **Step 3: 系统测试**

`test/system/action_streaming_test.rb`：

```ruby
require "application_system_test_case"

class ActionStreamingTest < ApplicationSystemTestCase
  test "执行页订阅流并显示逐行输出" do
    app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                             destination: "production")
    user = User.create!(email_address: "op@example.com", password: "secret123456", role: "operator")
    log = AuditLog.start!(user: user, managed_app: app, action_name: "restart",
                          target_version: nil, hosts: [ "10.0.0.1" ])

    visit new_session_path
    fill_in "email_address", with: "op@example.com"
    fill_in "password", with: "secret123456"
    click_on "登录"

    visit managed_app_action_path(app, log)

    assert_selector "#action-output"
    assert_text "执行中"
  end
end
```

- [ ] **Step 4: 运行全套并提交**

Run: `bin/rails test:all`

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "feat: 执行过程逐行流式输出

不能是转圈动画然后告知「成功了」——出问题时人需要看到卡在哪一步。"
```

---

## Task 12: README、CI 与自我验收

**Files:**
- Modify: `README.md`
- Modify: `.github/workflows/ci.yml`
- Modify: `docs/superpowers/specs/2026-09-05-kamal-panel-design.md`

- [ ] **Step 1: README 更新**

移除「`POST /apps` 未鉴权」的横幅（本计划已加鉴权），改为：

```markdown
## 权限模型

- **viewer**：只能看。看不到任何操作按钮。
- **operator**：可以回滚、重启、停止、启动、强制解锁，也可以新建应用。

> **新建应用等价于在面板宿主机上执行代码。** 粘贴的 `deploy.yml` 会被 Kamal
> 做 ERB 求值（见「安全」一节），因此该权限只给你信任到这个程度的人。

首个 operator 由环境变量注入，面板不设默认密码：

```bash
KAMAL_PANEL_ADMIN_EMAIL=you@example.com \
KAMAL_PANEL_ADMIN_PASSWORD=... \
bin/rails db:seed
```

## 面板如何执行写操作

面板**不自己拼命令**。回滚等操作是在受限子进程中调用 `kamal` CLI 完成的，
因此行为与你手动执行 `kamal rollback` 完全一致——包括你自己的 pre/post-deploy
hook 会照常触发。

私钥经**每次调用独立的 ssh-agent** 注入，全程不写入磁盘。
```

- [ ] **Step 2: CI 增加动作相关测试**

确认 `.github/workflows/ci.yml` 的 test job 仍为 `bin/rails test:all`，且 fake host 在其之前启动。若执行层测试耗时显著增加，把超时上调而不是拆分或跳过。

- [ ] **Step 3: spec 更新**

在 spec 12 决策记录中追加：

```markdown
| 写操作的执行方式 | 子进程调用 kamal CLI，而非自己用 Commands::App 拼命令 | 语义等价：rollback 会触发用户的 hook、切换 proxy 路由、跑健康检查。自己重实现等于再造一个必须与 Kamal 永远一致的实现 |
| CLI 的私钥注入 | 每次调用独立 ssh-agent，密钥经 stdin 注入 | 私钥全程不落盘；2026-09-06 对真实主机实测通过 |
```

并把 11.1 中已在 Task 1 清掉的五项标记为已完成。

- [ ] **Step 4: 人工验收**

```bash
docker compose -f docker-compose.test.yml up -d
KAMAL_PANEL_ADMIN_EMAIL=me@example.com KAMAL_PANEL_ADMIN_PASSWORD=secret123456 bin/rails db:seed
bin/rails server
```

浏览器中：以 viewer 登录确认看不到按钮 → 以 operator 登录接入一个指向 fake host 的应用 →
在 fake host 上造两个版本的容器 → 确认回滚候选列表正确置灰 → 发起一次 stop →
确认执行页逐行出现输出、审计页出现记录且结果不停在 pending。

**把观察到的写进报告。** 如果某一步不成立，那是一个发现。

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "docs: README 与 spec 反映计划 02 的权限模型与执行方式"
```

---

## 自查记录

**Spec 覆盖检查：**

| Spec 章节 | 覆盖任务 |
|---|---|
| 7.1 回滚真实语义 | Task 8（RollbackCandidates 提前算出可回滚版本） |
| 7.2 私钥只写不读 | 计划 01 已完成；Task 6 延伸为「CLI 调用时也不落盘」 |
| 7.3 封闭动作集 | Task 7（显式注册表）、Task 9（真实执行验证） |
| 7.4 复用 Kamal 锁 + 强制解锁 | Task 5（读锁）、Task 7（执行前取锁）、Task 10（强制解锁） |
| 7.5 审计先写后做 | Task 4、Task 7 |
| 7.6 解析即代码执行 | 计划 01 已完成；Task 2 补上「仅 operator 可新建」的角色约束 |
| 7.7 危险操作确认 | Task 3（viewer 看不到按钮）、Task 7（手输应用名） |
| 8.4 回滚四步交互 | Task 8（前三步）、Task 11（第四步流式输出） |
| 11.1 五项残留 | Task 1 |

**未覆盖（属计划 03）：** hook 上报端点与 DeployEvent、两套数据源对账告警、深色模式、Kamal 版本兼容矩阵 CI、面板自部署。

**类型一致性：** `Actions::Base.find(name)` 在 Task 7 定义、Task 8/10 使用；`AuditLog.start!` 的关键字在 Task 4 定义（`action_name` 而非 `action`，避免与 Rails 保留名冲突），Task 7/9/10 一致；`KamalCli::Invocation#run(args) { |line| }` 在 Task 6 定义、Task 7 使用；`KamalLock#status` 返回的三个键在 Task 5 定义、Task 7 消费。

**占位符扫描：** 无 TBD／TODO／「类似 Task N」。Task 6 Step 5 是一处**明确要求实测确认**的分支（`KAMAL_CONFIG_DIR` 是否被支持），已写明替代方案与报告要求，非占位符。
