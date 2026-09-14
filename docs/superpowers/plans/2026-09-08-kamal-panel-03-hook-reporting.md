# kamal-panel 实施计划 03：hook 上报与两套数据源对账

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让面板除了「现在是什么状态」之外还能回答「发生过什么」，并在两套数据源矛盾时把矛盾摆到台面上。

**Architecture:** 用户自愿在自己项目的 `.kamal/hooks/pre-deploy` 与 `post-deploy` 里放一段面板生成的 `curl`，打到 `POST /api/deploys`。一行 `DeployEvent` 代表一次部署尝试，两段上报分别填 `started_at` 与 `succeeded_at`。「上报了但观测不到」不建告警表、不加后台 job——给 `DeployEvent` 加一个 `observed_at`，由**本来就必然会跑的轮询**回填，告警是由此派生的查询。

**Tech Stack:** Ruby 4.0 / Rails 8.1 / SQLite / Solid Queue / Solid Cache / Hotwire / Minitest + Capybara / Docker Compose（fake host）

**Spec:** `docs/superpowers/specs/2026-09-07-kamal-panel-hook-reporting-design.md`（主设计：`docs/superpowers/specs/2026-09-05-kamal-panel-design.md`）

## Global Constraints

**每个任务的要求都隐含包含本节。**

- **面板挂掉绝不能让用户的部署失败或变慢**：生成的脚本必须带 `--max-time 5` 与结尾的 `|| true`。
- **告警计时只认服务端时刻**（`started_at` / `succeeded_at`）。`recorded_at` 是机器上的原文，可伪造、会时钟漂移，**只用于展示，绝不参与任何判定**。
- **上报字段与写操作参数完全隔离**：动作的 `cli_args` 由封闭动作集自己生成，任何上报字段都不得进入那条路径。
- **token 只存 SHA256 摘要**，明文只在生成的那一次展示，之后面板自己也读不回来。与 SSH 私钥的「只写不读」一致。
- **状态绝不能只靠颜色传达**：每个状态都要有文字标识。
- 所有测试 fixture 中的 deploy.yml **必须带 `builder: { arch: amd64 }`**，否则 Kamal 2.12.0 的校验器拒绝。
- **不 mock SSH**。涉及执行/采集的测试连真实 fake host：`docker compose -f docker-compose.test.yml up -d`。
- **本机内存紧张时不要跑 `bin/rails test:all`**：它会被系统 OOM kill，并让 `ssh_session_test` 的执行期截止断言漂成伪失败。分两段跑：`bin/rails test` 与 `bin/rails test:system`，都要前台、单进程。
- `bin/rails runner` 在 `RAILS_ENV=test` 下会污染测试库，不要用它做实验。
- UI 文案为中文；视觉方向为 37signals 语言。
- CI 跑 brakeman + rubocop + tests。**brakeman 通过不是覆盖的证据**——它在计划 01 中两次漏掉真实缺陷。

## 分阶段可交付

- **Task 1–3 完成后即可独立交付**：端点能收上报、事件正确落库，但界面上还看不到。
- **Task 4–6** 让它在界面上出现（回填、告警、历史）。
- **Task 7–8** 交付给用户（脚本生成页）并补上端到端与安全测试。

---

## 文件结构

```
app/
├── models/
│   ├── deploy_event.rb                  # 一行 = 一次部署尝试；阈值常量在这里
│   └── managed_app.rb                   # +hook token 摘要、+被拒上报的状态列
├── services/
│   ├── deploy_events/
│   │   ├── ingest.rb                    # 配对与幂等写入（乱序、丢包、重复都有归宿）
│   │   └── reconciler.rb                # 回填 observed_at
│   ├── deploy_alerts.rb                 # 两类告警的派生查询
│   └── hook_script.rb                   # 生成两段 curl 脚本
├── controllers/
│   ├── api/deploys_controller.rb        # 唯一的上报入口
│   └── hook_tokens_controller.rb        # 生成/重置 token
└── views/
    ├── managed_apps/_deploy_reporting.html.erb   # 「部署上报」区块
    ├── managed_apps/_deploy_history.html.erb     # 部署历史
    └── managed_apps/_deploy_alerts.html.erb      # 两类告警横幅
```

---

## Task 1: DeployEvent 与配对规则

**Files:**
- Create: `db/migrate/<ts>_create_deploy_events.rb`
- Create: `app/models/deploy_event.rb`
- Create: `app/services/deploy_events/ingest.rb`
- Test: `test/services/deploy_events/ingest_test.rb`

**Interfaces:**
- Produces: `DeployEvent`（列见下）；`DeployEvents::Ingest.call(managed_app:, phase:, attributes:)` → `{ event: DeployEvent, changed: Boolean }`。`phase` 是 `"started"` 或 `"succeeded"`；`attributes` 是已校验过的 `{ version:, performer:, command:, recorded_at: }`。`changed` 为 true 表示状态真的发生了变化（新建行，或首次补上 `succeeded_at`），Task 3 用它决定要不要触发 burst 轮询。
- Produces: `DeployEvent::UNOBSERVED_AFTER = 90.seconds`、`DeployEvent::UNFINISHED_AFTER = 15.minutes`，Task 5 消费。

- [ ] **Step 1: 写失败测试**

`test/services/deploy_events/ingest_test.rb`：

```ruby
require "test_helper"

class DeployEvents::IngestTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  def ingest(phase, version: "aaaaaaa", performer: "ci", command: "deploy",
             recorded_at: Time.current)
    DeployEvents::Ingest.call(
      managed_app: @app, phase: phase,
      attributes: { version: version, performer: performer, command: command,
                    recorded_at: recorded_at }
    )
  end

  test "pre-deploy 建行，只填 started_at" do
    result = ingest("started")

    assert result[:changed]
    assert_predicate result[:event].started_at, :present?
    assert_nil result[:event].succeeded_at
    assert_equal "hook", result[:event].source
  end

  test "post-deploy 补上同一次尝试，而不是另建一行" do
    started = ingest("started")[:event]
    result = ingest("succeeded")

    assert_equal started.id, result[:event].id
    assert result[:changed]
    assert_predicate result[:event].succeeded_at, :present?
    assert_equal 1, DeployEvent.count
  end

  test "pre 丢包、post 先到时建出只有 succeeded_at 的行" do
    result = ingest("succeeded")

    assert_nil result[:event].started_at
    assert_predicate result[:event].succeeded_at, :present?
  end

  test "重复的 pre-deploy 不建新行，也不算状态变化" do
    ingest("started")
    result = ingest("started")

    assert_equal 1, DeployEvent.count
    refute result[:changed], "重复上报不应再撬动一次 burst 轮询"
  end

  test "同一版本被重复部署是两行" do
    ingest("started")
    ingest("succeeded")
    ingest("started")

    assert_equal 2, DeployEvent.count
  end

  test "配对不跨应用" do
    other = ManagedApp.create!(name: "other", config_yaml: file_fixture("simple_deploy.yml").read,
                               destination: "production")
    DeployEvents::Ingest.call(managed_app: other, phase: "started",
                              attributes: { version: "aaaaaaa", performer: "ci",
                                            command: "deploy", recorded_at: Time.current })

    ingest("succeeded")

    assert_equal 2, DeployEvent.count
    assert_nil other.deploy_events.sole.succeeded_at
  end

  test "recorded_at 照存不误，但 started_at 用服务端时刻" do
    lie = 1.hour.from_now
    event = ingest("started", recorded_at: lie)[:event]

    assert_in_delta lie, event.recorded_at, 1.second
    assert_operator event.started_at, :<, 1.minute.from_now
  end
end
```

- [ ] **Step 2: 运行，确认失败**

Run: `bin/rails test test/services/deploy_events/ingest_test.rb`
Expected: FAIL —— `NameError: uninitialized constant DeployEvents`

- [ ] **Step 3: 迁移**

```bash
bin/rails generate migration CreateDeployEvents
```

把生成的文件内容替换为：

```ruby
class CreateDeployEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :deploy_events do |t|
      t.references :managed_app, null: false, foreign_key: true
      t.string :version, null: false
      t.string :performer
      t.string :destination
      t.string :command
      t.string :source, null: false, default: "hook"

      # 服务端收到两段上报的时刻——所有告警计时只认这两列
      t.datetime :started_at
      t.datetime :succeeded_at
      # 机器上的原文，只用于展示
      t.datetime :recorded_at
      # 轮询回填：该版本首次被观测到 running 的观测时间
      t.datetime :observed_at

      t.timestamps
    end

    # 配对查询：同一应用同一版本中 succeeded_at 为空的最近一行
    add_index :deploy_events, [ :managed_app_id, :version, :succeeded_at ]
    # 告警查询与历史列表都按时间倒序取
    add_index :deploy_events, [ :managed_app_id, :created_at ]
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 4: 模型**

`app/models/deploy_event.rb`：

```ruby
# 一行代表【一次部署尝试】，不是一条上报（spec 03 第 3 节）。
#
# pre-deploy 上报建行填 started_at，post-deploy 上报补同一行的 succeeded_at。
# 配不上就建一行只有 succeeded_at 的——丢包与乱序都要有归宿，不能静默丢弃。
class DeployEvent < ApplicationRecord
  belongs_to :managed_app

  # 只需盖住"容器起来后被下一轮轮询看到"这一小段。
  UNOBSERVED_AFTER = 90.seconds
  # 要盖住一次正常部署的全长（构建 + 健康检查）。与上面量级不同，
  # 合成同一个常量会让其中一个必然误报。
  UNFINISHED_AFTER = 15.minutes

  SOURCES = %w[hook].freeze

  validates :version, presence: true
  validates :source, inclusion: { in: SOURCES }

  scope :recent_first, -> { order(created_at: :desc) }

  # 面板真正确认过这一版跑起来了，与"上报说成功了"是两回事。
  def observed? = observed_at.present?

  def observation_delay
    return nil unless observed_at && succeeded_at

    observed_at - succeeded_at
  end
end
```

`app/models/managed_app.rb` 中 `belongs_to :ssh_credential` 之后加入：

```ruby
  has_many :deploy_events, dependent: :destroy
```

- [ ] **Step 5: 写入服务**

`app/services/deploy_events/ingest.rb`：

```ruby
module DeployEvents
  # 把一条上报并进"一次部署尝试"里。
  #
  # 返回的 :changed 表示状态真的发生了变化——新建行，或首次补上 succeeded_at。
  # 调用方据此决定要不要触发 burst 轮询：重复上报不该反复撬动一次 SSH 扇出。
  class Ingest
    STARTED   = "started".freeze
    SUCCEEDED = "succeeded".freeze
    PHASES    = [ STARTED, SUCCEEDED ].freeze

    def self.call(managed_app:, phase:, attributes:)
      new(managed_app, phase, attributes).call
    end

    def initialize(managed_app, phase, attributes)
      @managed_app = managed_app
      @phase = phase.to_s
      @attributes = attributes
    end

    def call
      raise ArgumentError, "未知阶段：#{phase.inspect}" unless PHASES.include?(phase)

      phase == STARTED ? ingest_started : ingest_succeeded
    end

    private
      attr_reader :managed_app, :phase, :attributes

      def ingest_started
        # 已经有一次尚未收尾的同版本尝试：这是 curl 重试或 CI 重跑同一步，
        # 不是新的一次部署。
        if (open = open_attempt)
          return { event: open, changed: false }
        end

        { event: create(started_at: Time.current), changed: true }
      end

      def ingest_succeeded
        if (open = open_attempt)
          open.update!(succeeded_at: Time.current, **carried_attributes)
          return { event: open, changed: true }
        end

        # pre 那次上报丢了（或压根没配 pre-deploy hook）。
        { event: create(succeeded_at: Time.current), changed: true }
      end

      def open_attempt
        managed_app.deploy_events
                   .where(version: attributes.fetch(:version), succeeded_at: nil)
                   .order(created_at: :desc)
                   .first
      end

      def create(**timestamps)
        managed_app.deploy_events.create!(
          source: "hook", destination: managed_app.destination,
          **carried_attributes, **timestamps
        )
      end

      def carried_attributes
        { version: attributes.fetch(:version),
          performer: attributes[:performer],
          command: attributes[:command],
          recorded_at: attributes[:recorded_at] }
      end
  end
end
```

- [ ] **Step 6: 运行，确认通过**

Run: `bin/rails test test/services/deploy_events/ingest_test.rb`
Expected: 7 runs, 0 failures

- [ ] **Step 7: 提交**

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "feat: DeployEvent——一行代表一次部署尝试，两段上报配对

丢包与乱序都要有归宿：post 先到就建只有 succeeded_at 的行，
重复的 pre 不建新行也不算状态变化（否则会反复撬动 SSH 扇出）。"
```

---

## Task 2: per-application 上报 token

**Files:**
- Create: `db/migrate/<ts>_add_hook_reporting_to_managed_apps.rb`
- Modify: `app/models/managed_app.rb`
- Test: `test/models/managed_app_hook_token_test.rb`

**Interfaces:**
- Produces: `ManagedApp#regenerate_hook_token!` → 明文 token（`String`，只在这一次拿得到）；`ManagedApp.find_by_hook_token(token)` → `ManagedApp | nil`；`ManagedApp#hook_reporting_enabled?` → `Boolean`；`ManagedApp#reject_hook!(message)` 写 `last_hook_rejection` / `last_hook_rejection_at`。Task 3、7 消费。

- [ ] **Step 1: 写失败测试**

`test/models/managed_app_hook_token_test.rb`：

```ruby
require "test_helper"

class ManagedAppHookTokenTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  test "未生成时上报未启用" do
    refute_predicate @app, :hook_reporting_enabled?
    assert_nil ManagedApp.find_by_hook_token("anything")
  end

  test "生成后能按明文找回应用" do
    token = @app.regenerate_hook_token!

    assert_predicate @app.reload, :hook_reporting_enabled?
    assert_equal @app, ManagedApp.find_by_hook_token(token)
  end

  test "明文不落库" do
    token = @app.regenerate_hook_token!

    row = ManagedApp.connection.select_one("SELECT * FROM managed_apps WHERE id = #{@app.id}")

    refute_includes row.values.map(&:to_s).join("\n"), token
  end

  test "重置让旧 token 立即失效" do
    old = @app.regenerate_hook_token!
    new = @app.regenerate_hook_token!

    refute_equal old, new
    assert_nil ManagedApp.find_by_hook_token(old)
    assert_equal @app, ManagedApp.find_by_hook_token(new)
  end

  test "空 token 不匹配任何应用" do
    @app.regenerate_hook_token!

    assert_nil ManagedApp.find_by_hook_token("")
    assert_nil ManagedApp.find_by_hook_token(nil)
  end

  test "被拒上报记在应用上" do
    @app.reject_hook!("收到 service=other 的上报，但这个 token 属于 blog")

    assert_match "service=other", @app.reload.last_hook_rejection
    assert_predicate @app.last_hook_rejection_at, :present?
  end
end
```

- [ ] **Step 2: 运行，确认失败**

Run: `bin/rails test test/models/managed_app_hook_token_test.rb`
Expected: FAIL —— `NoMethodError: undefined method 'hook_reporting_enabled?'`

- [ ] **Step 3: 迁移**

```bash
bin/rails generate migration AddHookReportingToManagedApps
```

内容：

```ruby
class AddHookReportingToManagedApps < ActiveRecord::Migration[8.1]
  def change
    # 只存摘要：明文只在生成的那一次展示，面板自己也读不回来。
    add_column :managed_apps, :hook_token_digest, :string
    add_index  :managed_apps, :hook_token_digest, unique: true

    # 沿用 last_poll_error 那套模式：这是"当前配置有问题"的状态，
    # 不是需要留存的历史，所以不单独建表。
    add_column :managed_apps, :last_hook_rejection, :text
    add_column :managed_apps, :last_hook_rejection_at, :datetime
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 4: 模型方法**

`app/models/managed_app.rb` 里加入（放在 `kamal_hooks_scripts` 之后）：

```ruby
  # 上报 token 只存摘要（spec 03 第 3 节）。明文在 regenerate 时返回一次，
  # 之后无论是面板还是数据库泄露都拿不回来——与 SSH 私钥的"只写不读"一致。
  def regenerate_hook_token!
    token = SecureRandom.urlsafe_base64(32)
    update!(hook_token_digest: self.class.hook_token_digest_for(token))
    token
  end

  def hook_reporting_enabled? = hook_token_digest.present?

  def reject_hook!(message)
    update_columns(last_hook_rejection: message.to_s.truncate(500),
                   last_hook_rejection_at: Time.current)
  end

  def self.hook_token_digest_for(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  def self.find_by_hook_token(token)
    return nil if token.blank?

    find_by(hook_token_digest: hook_token_digest_for(token))
  end
```

- [ ] **Step 5: 运行，确认通过**

Run: `bin/rails test test/models/managed_app_hook_token_test.rb`
Expected: 6 runs, 0 failures

- [ ] **Step 6: 提交**

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "feat: per-application 上报 token，只存 SHA256 摘要

明文只在生成的那一次拿得到；重置即覆盖摘要，旧值当场失效。"
```

---

## Task 3: POST /api/deploys

**Files:**
- Create: `app/controllers/api/deploys_controller.rb`
- Modify: `config/routes.rb`
- Test: `test/controllers/api/deploys_controller_test.rb`

**Interfaces:**
- Consumes: `ManagedApp.find_by_hook_token`、`ManagedApp#reject_hook!`（Task 2）；`DeployEvents::Ingest.call`（Task 1）；`PollCadence.mark_burst!`（已有）。
- Produces: `POST /api/deploys`，参数 `phase`（`started` / `succeeded`）、`service`、`destination`、`version`、`performer`、`recorded_at`、`command`。

**为什么继承 `ActionController::API`：** 它不带 CSRF、cookie 与 `allow_browser`——那三样都是为浏览器准备的，而这个端点的客户端是 `curl`。`ActionController::RateLimiting` 已包含在内（已核实）。

- [ ] **Step 1: 写失败测试**

`test/controllers/api/deploys_controller_test.rb`：

```ruby
require "test_helper"

class Api::DeploysControllerTest < ActionDispatch::IntegrationTest
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    @token = @app.regenerate_hook_token!
  end

  def post_report(token: @token, **overrides)
    params = { phase: "succeeded", service: "blog", destination: "production",
               version: "aaaaaaa", performer: "ci", command: "deploy",
               recorded_at: Time.current.iso8601 }.merge(overrides)

    post "/api/deploys", params: params,
         headers: { "Authorization" => "Bearer #{token}" }
  end

  test "认得的 token 收下上报，且不回任何内容" do
    post_report

    assert_response :no_content
    assert_equal "", response.body
    assert_equal 1, @app.deploy_events.count
  end

  test "不认的 token 是 401，不落任何行" do
    post_report(token: "nope")

    assert_response :unauthorized
    assert_equal 0, DeployEvent.count
  end

  test "service 与 token 不匹配是 409，并记在应用上" do
    post_report(service: "other")

    assert_response :conflict
    assert_equal 0, @app.deploy_events.count
    assert_match "other", @app.reload.last_hook_rejection
  end

  test "destination 与 token 不匹配是 409" do
    post_report(destination: "staging")

    assert_response :conflict
    assert_match "staging", @app.reload.last_hook_rejection
  end

  test "非法 version 是 422" do
    post_report(version: "a; rm -rf /")

    assert_response :unprocessable_entity
    assert_equal 0, @app.deploy_events.count
  end

  test "未知 phase 是 422" do
    post_report(phase: "whatever")

    assert_response :unprocessable_entity
  end

  test "状态发生变化时触发 burst 轮询" do
    post_report(phase: "started")

    assert_equal PollCadence::BURST, PollCadence.interval_for(@app)
  end

  test "重复上报不再撬动 burst" do
    post_report(phase: "started")
    Rails.cache.clear

    post_report(phase: "started")

    refute_equal PollCadence::BURST, PollCadence.interval_for(@app),
                 "重复上报不该反复触发一次 SSH 扇出"
  end

  test "超出限流后返回 429" do
    31.times { post_report }

    assert_response :too_many_requests
  end

  test "performer 与 command 过长时截断而不是报错" do
    post_report(performer: "x" * 500, command: "y" * 500)

    assert_response :no_content
    assert_operator @app.deploy_events.sole.performer.length, :<=, 255
  end
end
```

- [ ] **Step 2: 运行，确认失败**

Run: `bin/rails test test/controllers/api/deploys_controller_test.rb`
Expected: FAIL —— 路由不存在（`ActionController::RoutingError`）

- [ ] **Step 3: 路由**

`config/routes.rb` 中 `resources :audit_logs` 之前加入：

```ruby
  # hook 上报入口。客户端是 curl，不是浏览器——控制器因此继承
  # ActionController::API（无 CSRF、无 cookie、无 allow_browser）。
  namespace :api do
    resources :deploys, only: [ :create ]
  end
```

- [ ] **Step 4: 控制器**

`app/controllers/api/deploys_controller.rb`：

```ruby
module Api
  # 唯一的上报入口（spec 03 第 4 节）。
  #
  # 成功也不返回任何内容：token 是写入凭证，不能顺带变成读取面板状态的通道。
  #
  # 限流是硬要求而不是防御性编程——收到事件会触发 burst 轮询，也就是一个
  # token 能撬动面板对用户的所有机器发起 SSH 扇出。
  class DeploysController < ActionController::API
    # version 会进 UI、进告警文案、参与配对查询。这里按保守字符集收口，
    # 与"上报字段不进入任何 cli_args"是两道独立的防线。
    VERSION_FORMAT = /\A[A-Za-z0-9._-]{1,128}\z/
    TEXT_LIMIT = 255

    rate_limit to: 30, within: 1.minute, by: -> { request.headers["Authorization"].to_s }

    def create
      app = ManagedApp.find_by_hook_token(bearer_token)
      return head(:unauthorized) if app.nil?

      return head(:unprocessable_entity) unless valid_payload?
      return reject_mismatch(app) unless matches?(app)

      app.update_columns(last_hook_rejection: nil, last_hook_rejection_at: nil)

      result = DeployEvents::Ingest.call(managed_app: app, phase: params[:phase],
                                         attributes: ingest_attributes)
      # 只在状态真的变化时才撬动一次扇出。
      PollCadence.mark_burst!(app) if result[:changed]

      head :no_content
    end

    private
      def bearer_token
        request.headers["Authorization"].to_s[/\ABearer (.+)\z/, 1]
      end

      def valid_payload?
        DeployEvents::Ingest::PHASES.include?(params[:phase].to_s) &&
          params[:version].to_s.match?(VERSION_FORMAT)
      end

      def matches?(app)
        params[:service].to_s == app.service &&
          params[:destination].to_s == app.destination.to_s
      rescue Kamal::ConfigParser::ParseError
        # 配置现在解析不了，判断不了 service 是否匹配。这时候不猜：
        # 当作不匹配拒收，理由会写进 last_hook_rejection。
        false
      end

      def reject_mismatch(app)
        app.reject_hook!(
          "收到 service=#{params[:service]} / destination=#{params[:destination]} 的上报，" \
          "但这个 token 属于本应用。请检查是不是把 token 粘到了别的项目或别的 destination 的 hook 里。"
        )
        head :conflict
      end

      def ingest_attributes
        { version: params[:version].to_s,
          performer: params[:performer].to_s.truncate(TEXT_LIMIT).presence,
          command: params[:command].to_s.truncate(TEXT_LIMIT).presence,
          recorded_at: parsed_recorded_at }
      end

      # 机器上的原文，只用于展示。解析不了就丢掉，绝不因此拒收整条上报——
      # 也绝不用它做任何判定（那会让时钟漂移变成告警的开关）。
      def parsed_recorded_at
        Time.zone.parse(params[:recorded_at].to_s)
      rescue ArgumentError, TypeError
        nil
      end
  end
end
```

- [ ] **Step 5: 运行，确认通过**

Run: `bin/rails test test/controllers/api/deploys_controller_test.rb`
Expected: 10 runs, 0 failures

若 429 那例失败，检查 test 环境的 `Rails.cache`（限流计数存在缓存里）；`config/environments/test.rb` 已配 `:memory_store`，无需改动。

- [ ] **Step 6: 全套并提交**

Run: `bin/rails test`

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "feat: POST /api/deploys——收 hook 上报，限流并只在状态变化时撬动 burst

成功也不回内容：token 是写入凭证，不是读取面板状态的通道。
service/destination 与 token 不匹配时 409 并记在应用上，
否则 token 粘错的表现只会是「部署历史永远是空的」。"
```

---

## Task 4: 回填 observed_at

**Files:**
- Create: `app/services/deploy_events/reconciler.rb`
- Modify: `app/jobs/poll_managed_app_job.rb`
- Test: `test/services/deploy_events/reconciler_test.rb`

**Interfaces:**
- Consumes: `Observation.latest_for`（已有）、`DeployEvent`（Task 1）。
- Produces: `DeployEvents::Reconciler.call(managed_app)`。

- [ ] **Step 1: 写失败测试**

`test/services/deploy_events/reconciler_test.rb`：

```ruby
require "test_helper"

class DeployEvents::ReconcilerTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    @observed_at = 3.minutes.ago
  end

  def observe(version:, status: "running", host: "10.0.0.1")
    Observation.create!(managed_app: @app, host: host, role: "web",
                        container_name: "blog-web-production-#{version}",
                        version: version, docker_status: status,
                        reachable: true, observed_at: @observed_at)
  end

  def event(version: "aaaaaaa", succeeded_at: 5.minutes.ago)
    DeployEvent.create!(managed_app: @app, version: version, source: "hook",
                        succeeded_at: succeeded_at)
  end

  test "填的是观测时间，而不是当下" do
    e = event
    observe(version: "aaaaaaa")

    DeployEvents::Reconciler.call(@app)

    assert_in_delta @observed_at, e.reload.observed_at, 1.second
  end

  test "只认 running，exited 不算被观测到" do
    e = event
    observe(version: "aaaaaaa", status: "exited")

    DeployEvents::Reconciler.call(@app)

    assert_nil e.reload.observed_at
  end

  test "已经填过的不被后来的观测覆写" do
    first = 10.minutes.ago
    e = event
    e.update!(observed_at: first)
    observe(version: "aaaaaaa")

    DeployEvents::Reconciler.call(@app)

    assert_in_delta first, e.reload.observed_at, 1.second
  end

  test "不越过应用边界" do
    other = ManagedApp.create!(name: "other", config_yaml: file_fixture("simple_deploy.yml").read,
                               destination: "production")
    theirs = DeployEvent.create!(managed_app: other, version: "aaaaaaa", source: "hook",
                                 succeeded_at: 5.minutes.ago)
    observe(version: "aaaaaaa")

    DeployEvents::Reconciler.call(@app)

    assert_nil theirs.reload.observed_at
  end

  test "没有观测时什么都不做" do
    e = event

    DeployEvents::Reconciler.call(@app)

    assert_nil e.reload.observed_at
  end
end
```

- [ ] **Step 2: 运行，确认失败**

Run: `bin/rails test test/services/deploy_events/reconciler_test.rb`
Expected: FAIL —— `NameError: uninitialized constant DeployEvents::Reconciler`

- [ ] **Step 3: 实现**

`app/services/deploy_events/reconciler.rb`：

```ruby
module DeployEvents
  # 把"面板真的看见这一版在跑了"这件事回填到 DeployEvent 上（spec 03 第 5 节）。
  #
  # 填的是那条观测自己的 observed_at，不是 Time.current：延迟数字说的是
  # "机器上多久之后才看到它"，不是"面板多久之后才想起来算这件事"。
  class Reconciler
    RUNNING_STATUSES = %w[running restarting].freeze

    def self.call(managed_app)
      new(managed_app).call
    end

    def initialize(managed_app)
      @managed_app = managed_app
    end

    def call
      running_versions.each do |version, observed_at|
        managed_app.deploy_events
                   .where(version: version, observed_at: nil)
                   .update_all(observed_at: observed_at, updated_at: Time.current)
      end
    end

    private
      attr_reader :managed_app

      # version => 该版本最早的那条 running 观测时间
      def running_versions
        Observation.latest_for(managed_app)
                   .select { |o| RUNNING_STATUSES.include?(o.docker_status) && o.version.present? }
                   .group_by(&:version)
                   .transform_values { |rows| rows.map(&:observed_at).min }
      end
  end
end
```

- [ ] **Step 4: 运行，确认通过**

Run: `bin/rails test test/services/deploy_events/reconciler_test.rb`
Expected: 5 runs, 0 failures

- [ ] **Step 5: 接进轮询**

`app/jobs/poll_managed_app_job.rb`：在 `ProxyCollector` 那个 begin/rescue 之后、`if parse_error` 之前插入：

```ruby
    begin
      # 回填放在采集之后：它读的就是这一轮刚写下的观测。
      # 与两个采集器一样彼此隔离——它自己抛异常不能连累采集结果。
      DeployEvents::Reconciler.call(managed_app) unless parse_error
    rescue StandardError => e
      error ||= e
    end
```

- [ ] **Step 6: 写作业级测试**

`test/jobs/poll_managed_app_job_test.rb` 中追加（若文件不存在则创建，`require "test_helper"` + `class PollManagedAppJobTest < ExecutionLayerTest`）：

```ruby
  test "一轮轮询会回填 observed_at" do
    app = build_app_on_node_1
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")
    event = DeployEvent.create!(managed_app: app, version: "aaaaaaa", source: "hook",
                                succeeded_at: 1.minute.ago)

    PollManagedAppJob.perform_now(app)

    assert_predicate event.reload.observed_at, :present?
  end
```

其中 `build_app_on_node_1` 用与 `test/services/actions/execution_test.rb` 中 `build_app` 相同的 YAML（`service: blog` / `servers.web: 127.0.0.1` / `builder.arch: amd64` / `ssh.port: FakeHost::NODES.fetch("node-1")`）与凭据（`Credential.new(kind: "ssh_key", value: FakeHost.private_key)`）。

- [ ] **Step 7: 运行并提交**

Run: `bin/rails test test/jobs/poll_managed_app_job_test.rb test/services/deploy_events/reconciler_test.rb`

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "feat: 轮询回填 observed_at——用观测时间而不是当下

告警的唯一真相因此落在必然会跑的轮询路径上，
而不是一个挂了没人会发现的定时任务。"
```

---

## Task 5: 两类告警

**Files:**
- Create: `app/services/deploy_alerts.rb`
- Create: `app/views/managed_apps/_deploy_alerts.html.erb`
- Modify: `app/views/managed_apps/show.html.erb`
- Modify: `app/views/overviews/show.html.erb`
- Test: `test/services/deploy_alerts_test.rb`、`test/system/deploy_alerts_test.rb`

**Interfaces:**
- Consumes: `DeployEvent::UNOBSERVED_AFTER`、`DeployEvent::UNFINISHED_AFTER`（Task 1）。
- Produces: `DeployAlerts.new(managed_app).list` → `[{ kind: :unobserved | :unfinished, event:, message: String }]`；`DeployAlerts.new(managed_app).any?`。

- [ ] **Step 1: 写失败测试**

`test/services/deploy_alerts_test.rb`：

```ruby
require "test_helper"

class DeployAlertsTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  def event(**attrs)
    DeployEvent.create!({ managed_app: @app, version: "aaaaaaa", source: "hook" }.merge(attrs))
  end

  test "上报成功 91 秒仍未观测到就告警" do
    event(succeeded_at: 91.seconds.ago)

    alert = DeployAlerts.new(@app).list.sole

    assert_equal :unobserved, alert[:kind]
    assert_match "aaaaaaa", alert[:message]
    assert_match "未在任何机器上观测到", alert[:message]
  end

  test "89 秒还不告警——那只是还没轮到下一轮轮询" do
    event(succeeded_at: 89.seconds.ago)

    assert_empty DeployAlerts.new(@app).list
  end

  test "观测到了就不告警" do
    event(succeeded_at: 10.minutes.ago, observed_at: 9.minutes.ago)

    assert_empty DeployAlerts.new(@app).list
  end

  test "开了头 16 分钟没收尾就告警" do
    event(started_at: 16.minutes.ago)

    alert = DeployAlerts.new(@app).list.sole

    assert_equal :unfinished, alert[:kind]
    assert_match "至今未收到完成上报", alert[:message]
  end

  test "开了头 14 分钟不告警——一次正常部署本来就要这么久" do
    event(started_at: 14.minutes.ago)

    assert_empty DeployAlerts.new(@app).list
  end

  test "已收尾的不再算作开了头没收尾" do
    event(started_at: 30.minutes.ago, succeeded_at: 29.minutes.ago, observed_at: 29.minutes.ago)

    assert_empty DeployAlerts.new(@app).list
  end

  test "两类告警语义不同，同时存在时各占一条" do
    event(succeeded_at: 5.minutes.ago)
    event(version: "bbbbbbb", started_at: 30.minutes.ago)

    kinds = DeployAlerts.new(@app).list.map { |a| a[:kind] }

    assert_equal [ :unobserved, :unfinished ], kinds.sort_by(&:to_s).reverse
  end
end
```

- [ ] **Step 2: 运行，确认失败**

Run: `bin/rails test test/services/deploy_alerts_test.rb`
Expected: FAIL —— `NameError: uninitialized constant DeployAlerts`

- [ ] **Step 3: 实现**

`app/services/deploy_alerts.rb`：

```ruby
# 两套数据源的矛盾（spec 03 第 5 节）。
#
# 不建告警表、不加后台 job：告警是由 DeployEvent 的几个时间列派生出来的
# 查询，因此"观测到了"这件事一发生，告警自然就不成立了——不需要任何人
# 去点"我知道了"，也不存在"消解任务挂了导致告警永远挂着"。
#
# 两类告警的阈值量级不同，合成同一个会让其中一个必然误报。
class DeployAlerts
  def initialize(managed_app)
    @managed_app = managed_app
  end

  def list
    unobserved + unfinished
  end

  def any? = list.any?

  private
    attr_reader :managed_app

    def unobserved
      managed_app.deploy_events
                 .where(observed_at: nil)
                 .where.not(succeeded_at: nil)
                 .where(succeeded_at: ..DeployEvent::UNOBSERVED_AFTER.ago)
                 .recent_first
                 .map do |event|
        { kind: :unobserved, event: event,
          message: "#{event.version} 已上报部署成功（#{ago(event.succeeded_at)}），" \
                   "但未在任何机器上观测到" }
      end
    end

    def unfinished
      managed_app.deploy_events
                 .where(succeeded_at: nil)
                 .where.not(started_at: nil)
                 .where(started_at: ..DeployEvent::UNFINISHED_AFTER.ago)
                 .recent_first
                 .map do |event|
        { kind: :unfinished, event: event,
          message: "#{event.version} 于 #{event.started_at.strftime('%H:%M')} 开始部署，" \
                   "至今未收到完成上报" }
      end
    end

    def ago(time)
      "#{ApplicationController.helpers.time_ago_in_words(time)}前"
    end
end
```

- [ ] **Step 4: 运行，确认通过**

Run: `bin/rails test test/services/deploy_alerts_test.rb`
Expected: 7 runs, 0 failures

- [ ] **Step 5: 横幅**

`app/views/managed_apps/_deploy_alerts.html.erb`：

```erb
<%# 两套数据源矛盾时把矛盾摆到台面上，而不是挑一个来信任（主设计 6.4）。 %>
<% alerts = DeployAlerts.new(managed_app).list %>
<% if alerts.any? %>
  <div class="deploy-alerts" role="alert">
    <% alerts.each do |alert| %>
      <p class="deploy-alert deploy-alert-<%= alert[:kind] %>">
        <strong><%= alert[:kind] == :unobserved ? "上报未验证" : "部署未收尾" %></strong>
        —— <%= alert[:message] %>
      </p>
    <% end %>
  </div>
<% end %>
```

`app/views/managed_apps/show.html.erb`：在 `<h1><%= @managed_app.name %></h1>` 之后立刻插入：

```erb
<%= render "managed_apps/deploy_alerts", managed_app: @managed_app %>
```

- [ ] **Step 6: 总览页的文字标识**

总览网格在 `app/views/overviews/_grid.html.erb`（`show.html.erb` 只是渲染它），循环变量是 `app`，
应用名那一格出现两次（第 22 行的解析失败分支与第 34 行的正常分支）。**两处都要改**，否则解析
失败的应用会漏掉这个标识：

```erb
<td>
  <%= link_to app.name, app %>
  <% if DeployAlerts.new(app).any? %>
    <span class="badge badge-unverified">上报未验证</span>
  <% end %>
</td>
```

这一行必须是**文字**，不能只加一个颜色（主设计的硬约束）。

- [ ] **Step 7: 系统测试**

`test/system/deploy_alerts_test.rb`：

```ruby
require "application_system_test_case"

class DeployAlertsTest < ApplicationSystemTestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    sign_in_as(User.create!(email_address: "v@example.com", password: "secret123456",
                            role: "viewer"))
  end

  test "上报成功但观测不到时详情页挂出告警，观测到之后自动消失" do
    event = DeployEvent.create!(managed_app: @app, version: "aaaaaaa", source: "hook",
                                succeeded_at: 5.minutes.ago)

    visit managed_app_path(@app)
    assert_text "未在任何机器上观测到"

    event.update!(observed_at: 1.minute.ago)

    visit managed_app_path(@app)
    assert_no_text "未在任何机器上观测到"
  end
end
```

- [ ] **Step 8: 运行并提交**

Run: `bin/rails test test/services/deploy_alerts_test.rb && bin/rails test:system`

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "feat: 两类对账告警——上报未验证与部署未收尾

阈值量级不同（90 秒 vs 15 分钟），合成一个会让其中一个必然误报。
告警是派生查询，观测一到就自然消解，不需要谁去点「我知道了」。"
```

---

## Task 6: 部署历史

**Files:**
- Create: `app/views/managed_apps/_deploy_history.html.erb`
- Modify: `app/views/managed_apps/show.html.erb`
- Test: `test/system/deploy_history_test.rb`

**Interfaces:**
- Consumes: `DeployEvent#observation_delay`（Task 1）、`ManagedApp#hook_reporting_enabled?`（Task 2）。

- [ ] **Step 1: 写失败测试**

`test/system/deploy_history_test.rb`：

```ruby
require "application_system_test_case"

class DeployHistoryTest < ApplicationSystemTestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    sign_in_as(User.create!(email_address: "v@example.com", password: "secret123456",
                            role: "viewer"))
  end

  test "没配上报时给的是排查提示，不是一个空表格" do
    visit managed_app_path(@app)

    assert_text "还没收到任何上报"
    assert_text "curl -v"
  end

  test "有事件时列出版本、发起人与观测延迟" do
    DeployEvent.create!(managed_app: @app, version: "aaaaaaa", source: "hook",
                        performer: "ci-bot", command: "deploy",
                        started_at: 12.minutes.ago, succeeded_at: 10.minutes.ago,
                        observed_at: 10.minutes.ago + 77.seconds)

    visit managed_app_path(@app)

    assert_text "aaaaaaa"
    assert_text "ci-bot"
    # 延迟必须显示出来：这就是"曾经延迟过"的痕迹
    assert_text "77 秒"
  end

  test "尚未观测到的那行如实说未验证" do
    DeployEvent.create!(managed_app: @app, version: "bbbbbbb", source: "hook",
                        succeeded_at: 2.minutes.ago)

    visit managed_app_path(@app)

    assert_text "未验证"
  end
end
```

- [ ] **Step 2: 运行，确认失败**

Run: `bin/rails test test/system/deploy_history_test.rb`
Expected: FAIL —— 页面上没有这些文字

- [ ] **Step 3: 实现**

`app/views/managed_apps/_deploy_history.html.erb`：

```erb
<h2>部署历史</h2>

<% events = managed_app.deploy_events.recent_first.limit(50) %>
<% if events.empty? %>
  <%# 空表格看不出所以然。401（token 不认）与 429（限流）拿不到应用上下文，
      面板上看不见——所以这里直接给排查路径，这是那个盲点唯一的出口
      （spec 03 第 8 节）。 %>
  <p class="empty-hint">
    还没收到任何上报。
    <% if managed_app.hook_reporting_enabled? %>
      若你已经放好了 hook：确认脚本有可执行位（<code>chmod +x .kamal/hooks/post-deploy</code>）、
      token 没粘错，并在部署机上用 <code>curl -v</code> 手跑一次那段命令看看返回码。
    <% else %>
      在下面的「部署上报」区块生成 token，就能在这里看到每次部署。
    <% end %>
  </p>
<% else %>
  <table class="deploy-history">
    <thead>
      <tr><th>版本</th><th>发起人</th><th>命令</th><th>开始</th><th>完成</th><th>观测</th></tr>
    </thead>
    <tbody>
      <% events.each do |event| %>
        <tr>
          <td><code><%= event.version %></code></td>
          <td><%= event.performer.presence || "—" %></td>
          <td><%= event.command.presence || "—" %></td>
          <td><%= event.started_at ? l(event.started_at, format: :short) : "（未收到）" %></td>
          <td><%= event.succeeded_at ? l(event.succeeded_at, format: :short) : "（未收到）" %></td>
          <td>
            <% if event.observed?  %>
              <%# 留痕：告警消解之后，"那次拖了多久"仍然查得出来 %>
              延迟 <%= event.observation_delay.round %> 秒
            <% else %>
              未验证
            <% end %>
          </td>
        </tr>
      <% end %>
    </tbody>
  </table>
<% end %>
```

`app/views/managed_apps/show.html.erb`：在文件末尾（操作区之后）加入：

```erb
<%= render "managed_apps/deploy_history", managed_app: @managed_app %>
```

- [ ] **Step 4: 运行，确认通过**

Run: `bin/rails test test/system/deploy_history_test.rb`
Expected: 3 runs, 0 failures

若 `l(event.started_at, format: :short)` 报缺少本地化格式，改用 `event.started_at.strftime("%m-%d %H:%M")`。

- [ ] **Step 5: 提交**

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "feat: 部署历史——含观测延迟，空状态直接给排查路径

401 与 429 在面板上没有出口（拿不到应用上下文），
所以「还没收到任何上报」旁边必须写清楚怎么自查。"
```

---

## Task 7: 「部署上报」区块与脚本生成

**Files:**
- Create: `app/services/hook_script.rb`
- Create: `app/controllers/hook_tokens_controller.rb`
- Create: `app/views/managed_apps/_deploy_reporting.html.erb`
- Modify: `config/routes.rb`、`app/views/managed_apps/show.html.erb`
- Test: `test/services/hook_script_test.rb`、`test/system/hook_setup_test.rb`

**Interfaces:**
- Consumes: `ManagedApp#regenerate_hook_token!`（Task 2）。
- Produces: `HookScript.new(managed_app, base_url:, token:)` → `#pre_deploy` / `#post_deploy`（均为 `String`）；`POST /apps/:managed_app_id/hook_token`（operator）。

- [ ] **Step 1: 写失败测试**

`test/services/hook_script_test.rb`：

```ruby
require "test_helper"

class HookScriptTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    @script = HookScript.new(@app, base_url: "https://panel.example.com", token: "T0KEN")
  end

  test "两段脚本只差 phase" do
    assert_match "phase=started", @script.pre_deploy
    assert_match "phase=succeeded", @script.post_deploy
  end

  test "面板挂掉不能拖垮用户的部署" do
    [ @script.pre_deploy, @script.post_deploy ].each do |body|
      assert_match "--max-time 5", body
      assert_match "|| true", body
    end
  end

  test "带上端点与 token" do
    assert_match "https://panel.example.com/api/deploys", @script.pre_deploy
    assert_match "Authorization: Bearer T0KEN", @script.pre_deploy
  end

  test "送的是 Kamal 自己的环境变量" do
    %w[KAMAL_SERVICE KAMAL_DESTINATION KAMAL_VERSION KAMAL_PERFORMER
       KAMAL_RECORDED_AT KAMAL_COMMAND].each do |var|
      assert_match var, @script.post_deploy
    end
  end
end
```

- [ ] **Step 2: 运行，确认失败**

Run: `bin/rails test test/services/hook_script_test.rb`
Expected: FAIL —— `NameError: uninitialized constant HookScript`

- [ ] **Step 3: 实现脚本生成**

`app/services/hook_script.rb`：

```ruby
# 面板生成、用户自愿放进自己项目的 .kamal/hooks/ 的两段脚本（spec 03 第 6 节）。
#
# --max-time 5 与结尾的 || true 都是硬性的：面板挂掉或变慢，绝不能让
# 用户的部署失败或卡住。没有这两样，没人敢加这个 hook。
class HookScript
  def initialize(managed_app, base_url:, token:)
    @managed_app = managed_app
    @base_url = base_url.to_s.chomp("/")
    @token = token
  end

  def pre_deploy  = script("pre-deploy", "started")
  def post_deploy = script("post-deploy", "succeeded")

  private
    attr_reader :managed_app, :base_url, :token

    def script(filename, phase)
      <<~SH
        #!/bin/sh
        # .kamal/hooks/#{filename}
        curl -sf --max-time 5 -X POST "#{base_url}/api/deploys" \\
          -H "Authorization: Bearer #{token}" \\
          -d phase=#{phase} \\
          -d service="$KAMAL_SERVICE" -d destination="$KAMAL_DESTINATION" \\
          -d version="$KAMAL_VERSION" -d performer="$KAMAL_PERFORMER" \\
          -d recorded_at="$KAMAL_RECORDED_AT" -d command="$KAMAL_COMMAND" || true
      SH
    end
end
```

- [ ] **Step 4: 控制器与路由**

`config/routes.rb` 中把 managed_apps 那块改成：

```ruby
  resources :managed_apps, path: "apps", only: [ :index, :new, :create, :show ] do
    resources :actions, only: [ :create, :show ]
    resource :hook_token, only: [ :create ]
  end
```

`app/controllers/hook_tokens_controller.rb`：

```ruby
# 生成 / 重置上报 token。
#
# 明文只在这一次的 flash 里出现，不落库、不再展示第二次——
# 与 SSH 私钥的"只写不读"一致（spec 03 第 3 节）。
class HookTokensController < ApplicationController
  before_action :require_operator!

  def create
    app = ManagedApp.find(params[:managed_app_id])
    token = app.regenerate_hook_token!

    redirect_to app, flash: { hook_token: token }
  end
end
```

- [ ] **Step 5: 区块视图**

`app/views/managed_apps/_deploy_reporting.html.erb`：

```erb
<h2>部署上报</h2>

<p class="hint">
  可选增强：在你自己项目的 <code>.kamal/hooks/</code> 里放两段 curl，
  面板就能显示"谁在什么时候部署了哪一版"，并在上报与实际观测矛盾时告警。
  不配也不影响面板的其他功能。
</p>

<% if (token = flash[:hook_token]) %>
  <%# 明文只在这一次出现。这句话必须说在展示旁边，而不是等人吃了亏才知道。 %>
  <div class="hook-token-reveal">
    <p><strong>下面两段脚本只显示这一次。</strong>离开这个页面后就只能重新生成（旧 token 当场失效）。</p>

    <% script = HookScript.new(@managed_app, base_url: request.base_url, token: token) %>
    <h3>.kamal/hooks/pre-deploy</h3>
    <pre><code><%= script.pre_deploy %></code></pre>
    <h3>.kamal/hooks/post-deploy</h3>
    <pre><code><%= script.post_deploy %></code></pre>

    <p>两个文件都要有可执行位：<code>chmod +x .kamal/hooks/pre-deploy .kamal/hooks/post-deploy</code></p>
  </div>
<% end %>

<% if @managed_app.last_hook_rejection.present? %>
  <p class="hook-rejection" role="alert">
    <strong>有上报被拒收</strong>（<%= time_ago_in_words(@managed_app.last_hook_rejection_at) %>前）
    —— <%= @managed_app.last_hook_rejection %>
  </p>
<% end %>

<%= operator_only do %>
  <%= button_to @managed_app.hook_reporting_enabled? ? "重新生成 token（旧的立即失效）" : "生成上报 token",
                managed_app_hook_token_path(@managed_app), method: :post %>
<% end %>
```

`app/views/managed_apps/show.html.erb`：在部署历史那一行之后加入：

```erb
<%= render "managed_apps/deploy_reporting", managed_app: @managed_app %>
```

- [ ] **Step 6: 端到端系统测试——页面给出的脚本真的能用**

`test/system/hook_setup_test.rb`：

```ruby
require "application_system_test_case"
require "net/http"

# 这条守的是别的测试都守不住的那种失败：端点单测过、页面单测过，
# 但页面给出的参数名与端点期望的不一致，于是用户照抄下来永远收不到数据。
class HookSetupTest < ApplicationSystemTestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    sign_in_as(User.create!(email_address: "op@example.com", password: "secret123456",
                            role: "operator"))
  end

  test "照着页面上的脚本发一次请求，部署历史就出现一行" do
    visit managed_app_path(@app)
    click_on "生成上报 token"

    script = find("pre", text: "phase=succeeded").text
    token = script[/Bearer (\S+)/, 1]
    assert token.present?, "页面上的脚本里应当带着 token"

    # 直接打 Capybara 起的那个 server，用的是脚本里出现的参数名
    uri = URI.join(page.server_url, "/api/deploys")
    response = post_hook_report(uri, token,
                                "phase" => "succeeded",
                                "service" => "blog",
                                "destination" => "production",
                                "version" => "aaaaaaa",
                                "performer" => "ci",
                                "command" => "deploy",
                                "recorded_at" => Time.current.iso8601)

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
```

`Net::HTTP.post_form` 不支持自定义 header，所以在 `test/application_system_test_case.rb` 里
补一个**实例**方法（放在 `sign_in_as` 之后）：

```ruby
  # Net::HTTP.post_form 不支持自定义 header，这里补一个。
  def post_hook_report(uri, token, params)
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{token}"
    request.set_form_data(params)
    Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
  end
```

- [ ] **Step 7: 运行并提交**

Run: `bin/rails test test/services/hook_script_test.rb && bin/rails test:system`

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "feat: 「部署上报」区块——生成 token 并一次性展示两段脚本

系统测试把页面上那段脚本里的 URL、参数名与 token 原样取出来真打一次，
守住「端点和页面各自都对、拼起来不通」这种谁也发现不了的失败。"
```

---

## Task 8: 完整链路与安全边界

**Files:**
- Test: `test/system/deploy_reconciliation_test.rb`、`test/controllers/api/deploys_isolation_test.rb`
- Modify: `README.md`、`docs/superpowers/specs/2026-09-05-kamal-panel-design.md`

**Interfaces:**
- Consumes: 前七个任务的全部产出。

这个任务不写新的产品代码。主设计 9.4 列的三个必测场景里，第三个「上报了但观测不到」到这里才真的被测到——在此之前它只是纸面承诺。

- [ ] **Step 1: 完整链路测试**

`test/system/deploy_reconciliation_test.rb`：

```ruby
require "application_system_test_case"

# 主设计 9.4 的第三个场景：POST 一个 DeployEvent 但不实际启动容器，
# 超时后必须出现矛盾告警；容器真的起来之后告警必须自动消失、痕迹必须留下。
class DeployReconciliationTest < ApplicationSystemTestCase
  setup do
    FakeHost.ensure_ready!
    FakeHost.reset_all!

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

    @app = ManagedApp.create!(name: "blog", config_yaml: yaml, destination: "production",
                              ssh_credential: Credential.new(kind: "ssh_key",
                                                             value: FakeHost.private_key))
    sign_in_as(User.create!(email_address: "v@example.com", password: "secret123456",
                            role: "viewer"))
  end

  test "上报了但机器上没有，超时后告警；容器起来后告警消失且留下延迟" do
    event = DeployEvent.create!(managed_app: @app, version: "aaaaaaa", source: "hook",
                                succeeded_at: Time.current)

    PollManagedAppJob.perform_now(@app)   # 真实采集：此刻什么容器都没有
    assert_nil event.reload.observed_at

    travel DeployEvent::UNOBSERVED_AFTER + 1.second do
      visit managed_app_path(@app)
      assert_text "未在任何机器上观测到"
    end

    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")
    PollManagedAppJob.perform_now(@app)

    assert_predicate event.reload.observed_at, :present?

    visit managed_app_path(@app)
    assert_no_text "未在任何机器上观测到"
    assert_text "延迟"
  end
end
```

- [ ] **Step 2: 运行**

Run: `bin/rails test test/system/deploy_reconciliation_test.rb`
Expected: 1 run, 0 failures

若 `travel` 不可用，在文件顶部 `include ActiveSupport::Testing::TimeHelpers`。

- [ ] **Step 3: 安全边界测试**

`test/controllers/api/deploys_isolation_test.rb`：

```ruby
require "test_helper"

# 上报字段与写操作参数完全隔离：动作的 cli_args 由封闭动作集自己生成。
# 这条要显式钉住，而不是靠"我知道它们没连着"。
class Api::DeploysIsolationTest < ActionDispatch::IntegrationTest
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    @token = @app.regenerate_hook_token!
  end

  test "带 shell 元字符的 version 直接被拒，不落库" do
    [ "a; rm -rf /", "$(whoami)", "`id`", "../../etc/passwd", "a b" ].each do |bad|
      post "/api/deploys",
           params: { phase: "succeeded", service: "blog", destination: "production",
                     version: bad, performer: "ci", command: "deploy" },
           headers: { "Authorization" => "Bearer #{@token}" }

      assert_response :unprocessable_entity, "#{bad.inspect} 不该被接受"
    end

    assert_equal 0, DeployEvent.count
  end

  test "上报里的 version 不会进入任何动作的 cli_args" do
    post "/api/deploys",
         params: { phase: "succeeded", service: "blog", destination: "production",
                   version: "aaaaaaa", performer: "ci", command: "deploy" },
         headers: { "Authorization" => "Bearer #{@token}" }
    assert_response :no_content

    # 动作的版本号来自调用方显式传入的 target_version，与上报无关
    args = Actions::Restart.new(@app, target_version: "bbbbbbb").cli_args

    assert_includes args, "bbbbbbb"
    refute_includes args.join(" "), "aaaaaaa"
  end
end
```

Run: `bin/rails test test/controllers/api/deploys_isolation_test.rb`

- [ ] **Step 4: README**

`README.md` 的「How the panel performs write operations」一节之后插入新一节：

```markdown
## Deploy reporting (optional)

SSH polling answers "what is running right now". It cannot answer "who deployed this,
when, and did the previous attempt fail?" — a failed deploy leaves the running version
unchanged, so polling sees nothing at all.

Kamal already runs your `.kamal/hooks/*` during a deploy and hands them
`KAMAL_SERVICE`, `KAMAL_VERSION`, `KAMAL_PERFORMER`, `KAMAL_DESTINATION`,
`KAMAL_RECORDED_AT` and `KAMAL_COMMAND`. The panel gives you two `curl` snippets —
one for `pre-deploy`, one for `post-deploy` — generated per application from its
detail page, and stores what they report as deploy history.

**This is optional.** Without it everything else works; you just don't get deploy
history, and the panel can't tell you "this version was reported deployed but never
showed up on any machine".

Two properties of the generated snippets are non-negotiable, and you should check they
survive any edit you make:

- `--max-time 5` and a trailing `|| true`. **The panel going down or getting slow must
  never fail or stall your deploy.**
- The hook files need the executable bit (`chmod +x`) — Kamal runs them as executables.

The reporting token is per application and is shown **once**, at generation time; the
panel stores only its SHA256 digest and cannot show it to you again. Regenerating
invalidates the previous one immediately.

When a report says a version deployed successfully but no machine is observed running it
within 90 seconds, the panel says so on the application page rather than picking one of
the two sources to trust. The warning clears itself once the version is observed, and the
history row keeps the delay — so "every deploy takes four minutes to actually show up"
stays visible as a pattern.
```

- [ ] **Step 5: 主设计回指**

`docs/superpowers/specs/2026-09-05-kamal-panel-design.md` 的 5.4 节末尾追加一行：

```markdown
> 本节的完整设计见子设计 `2026-09-07-kamal-panel-hook-reporting-design.md`（计划 03 实施）。
```

并在 9.4 的三场景表格中，把「上报了但观测不到」那一行的断言列改为：

```markdown
| **上报了但观测不到** | POST 一个 DeployEvent 但不实际启动容器 | 超时后出现矛盾告警（`test/system/deploy_reconciliation_test.rb`） |
```

- [ ] **Step 6: 两段跑全套并提交**

Run: `bin/rails test`
Run: `bin/rails test:system`

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "test: 对账的完整链路与上报字段的隔离边界

主设计 9.4 的第三个场景到这里才真的被测到，此前只是纸面承诺。"
```

---

## 自查记录

**Spec 覆盖检查：**

| 子设计章节 | 覆盖任务 |
|---|---|
| 3 数据模型（DeployEvent、配对规则） | Task 1 |
| 3 数据模型（token 摘要、被拒上报状态列） | Task 2 |
| 4 端点与认证（401/409/422/429/204、限流、burst 只在变化时） | Task 3 |
| 4 输入校验与字段隔离 | Task 3（校验）、Task 8（隔离断言） |
| 5 回填 | Task 4 |
| 5 两类告警与呈现位置 | Task 5 |
| 5 部署历史与空状态 | Task 6 |
| 6 脚本生成与一次性展示 | Task 7 |
| 7 测试策略 | 分散在各任务，端到端两条在 Task 7、8 |
| 8 已知限制（401/429 无出口） | Task 6 的空状态排查提示 |

**未覆盖（属后续轮次）：** `inferred` 事件、Kamal 版本兼容矩阵 CI、面板自部署、深色模式。

**类型一致性：** `DeployEvents::Ingest.call(managed_app:, phase:, attributes:)` 在 Task 1 定义、Task 3 使用，返回 `{ event:, changed: }` 两处一致；`DeployEvent::UNOBSERVED_AFTER` / `UNFINISHED_AFTER` 在 Task 1 定义、Task 5 与 Task 8 使用；`ManagedApp#regenerate_hook_token!` / `.find_by_hook_token` / `#hook_reporting_enabled?` / `#reject_hook!` 在 Task 2 定义，Task 3、6、7 使用；`DeployAlerts#list` 返回的 `{kind:, event:, message:}` 在 Task 5 定义并在同任务的视图中消费；`HookScript#pre_deploy` / `#post_deploy` 在 Task 7 定义并在同任务视图中消费；`DeployEvents::Reconciler.call(managed_app)` 在 Task 4 定义并在同任务接进 `PollManagedAppJob`。

**占位符扫描：** 无 TBD / TODO / 「类似 Task N」。Task 6 Step 4 给了 `l()` 报错时的替代写法，Task 2 Step 2 给出了预期的失败信息，两处都是**给出确定做法的分支**，不是待填空白。
