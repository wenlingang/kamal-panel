# kamal-panel 实施计划 05：从观测推断的部署事件

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让没配 hook 上报的应用也有部署历史——但只写面板真的知道的那一件事：版本变了。

**Architecture:** 轮询每轮算一次「收敛版本」（配置里每台 host 都有可达且 running 的观测，且版本一致）。收敛版本与 `ManagedApp#last_converged_version` 不同就记一条 `source: "inferred"` 的 `DeployEvent`。首次收敛只写基线不记事件；已有同版本 hook 事件（且落在当前收敛期内）时让位不记。

**Tech Stack:** Ruby 4.0 / Rails 8.1 / SQLite / Solid Queue / Hotwire / Minitest + Capybara / Docker Compose（fake host）

**Spec:** `docs/superpowers/specs/2026-09-09-kamal-panel-inferred-events-design.md`（主设计：`docs/superpowers/specs/2026-09-05-kamal-panel-design.md`；前一子设计：`docs/superpowers/specs/2026-09-07-kamal-panel-hook-reporting-design.md`）

## Global Constraints

**每个任务的要求都隐含包含本节。**

- **不把推测写成事实**。推断只产出「版本变了」这一个事实；`performer` / `command` 留空，不编 `"unknown"`。
- **收敛要求配置里的每一台 host 都有可达且 running 的观测**。任何一台失联、或某台一行 running 都没有，就不算收敛，**不记事件且不动状态**。
- **首次收敛只写基线，不产生事件**。一个早就在跑 V1 的应用刚被接进来，它不是「今天部署的 V1」。
- **去重要带时间边界**，比较用的是**更新之前**的 `last_converged_at`；**让位不记事件时同样要更新那两列**。
- `last_converged_at` 存的是**观测时刻**（那批 running 观测里最早的 `observed_at`），不是 `Time.current`。
- **状态绝不能只靠颜色传达**：来源标识必须是文字。
- 所有测试 fixture 中的 deploy.yml **必须带 `builder: { arch: amd64 }`**，否则 Kamal 2.12.0 的校验器拒绝。
- **不 mock SSH**。链路测试连真实 fake host：`docker compose -f docker-compose.test.yml up -d`。
- **不要跑 `bin/rails test:all`**（本机内存不足会被 OOM kill）。分两段跑 `bin/rails test` 与 `bin/rails test:system`，**前台、单进程、不要并行**。
- 跑测试前先 `docker info` 确认 daemon 活着——本机 Docker 掉过，掉了会让一批 FakeHost 测试报成片 error，与代码无关。
- 注释写「为什么」而非「做了什么」，中文；UI 文案中文。
- CI 跑 brakeman + rubocop + tests，两者都要干净。

## 分阶段可交付

- **Task 1–2 完成后即可独立交付**：推断逻辑跑起来并真的落库，界面上还看不出来源区别。
- **Task 3** 让两类事实在界面上可分辨，并把文档改对。

---

## 文件结构

```
app/
├── models/
│   ├── deploy_event.rb        # SOURCES 放宽；observation_delay_text 为 inferred 分一支
│   └── managed_app.rb         # +last_converged_version / +last_converged_at
├── services/deploy_events/
│   └── inferrer.rb            # 收敛判定 + 基线 + 去重 + 建事件
├── jobs/poll_managed_app_job.rb  # 在 Reconciler 之后挂上 Inferrer
└── views/managed_apps/
    └── _deploy_history.html.erb  # 「来源」列、推断行的三处显示、空状态文案
```

---

## Task 1: 收敛判定与推断事件

**Files:**
- Create: `db/migrate/<ts>_add_convergence_tracking_to_managed_apps.rb`
- Create: `app/services/deploy_events/inferrer.rb`
- Modify: `app/models/deploy_event.rb`（`SOURCES`）
- Test: `test/services/deploy_events/inferrer_test.rb`

**Interfaces:**
- Consumes: `Observation.latest_for(managed_app)`（已有）、`ManagedApp#cached_app_hosts`（已有）、`DeployEvent`（已有，列：`version` / `started_at` / `succeeded_at` / `observed_at` / `source` / `performer` / `command`）。
- Produces: `DeployEvents::Inferrer.call(managed_app)`；`ManagedApp#last_converged_version`、`#last_converged_at` 两列。Task 2、3 消费。

- [ ] **Step 1: 写失败测试**

`test/services/deploy_events/inferrer_test.rb`：

```ruby
require "test_helper"

class DeployEvents::InferrerTest < ActiveSupport::TestCase
  setup do
    @managed_app = ManagedApp.create!(name: "blog",
                                      config_yaml: file_fixture("two_host_deploy.yml").read,
                                      destination: "production")
  end

  # two_host_deploy.yml 的两台机器；一次"全体收敛"必须两台都有可达且 running 的观测
  HOSTS = %w[10.0.0.1 10.0.0.2].freeze

  def observe(host:, version:, status: "running", reachable: true, at: Time.current, role: "web")
    Observation.create!(managed_app: @managed_app, host: host, role: role,
                        container_name: "blog-#{role}-production-#{version}",
                        version: version, docker_status: status,
                        reachable: reachable, observed_at: at)
  end

  def converge(version:, at: Time.current)
    HOSTS.each { |host| observe(host: host, version: version, at: at) }
  end

  test "首次收敛只写基线，不产生事件" do
    converge(version: "aaaaaaa")

    DeployEvents::Inferrer.call(@managed_app)

    assert_equal 0, @managed_app.deploy_events.count,
                 "刚接入的应用早就在跑这一版了，它不是今天部署的"
    assert_equal "aaaaaaa", @managed_app.reload.last_converged_version
    assert_predicate @managed_app.last_converged_at, :present?
  end

  test "收敛版本变化时记一条 inferred" do
    converge(version: "aaaaaaa", at: 10.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)

    converged_at = 1.minute.ago
    converge(version: "bbbbbbb", at: converged_at)
    DeployEvents::Inferrer.call(@managed_app)

    event = @managed_app.deploy_events.sole
    assert_equal "bbbbbbb", event.version
    assert_equal "inferred", event.source
    assert_nil event.started_at
    assert_nil event.performer
    assert_nil event.command
    assert_in_delta converged_at, event.succeeded_at, 1.second
    assert_in_delta converged_at, event.observed_at, 1.second
    assert_equal "bbbbbbb", @managed_app.reload.last_converged_version
  end

  test "混合版本不算收敛：不记事件也不动状态" do
    converge(version: "aaaaaaa", at: 10.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)

    # 滚动部署中途：一台已经是新版，另一台还没换
    observe(host: "10.0.0.1", version: "bbbbbbb")
    observe(host: "10.0.0.2", version: "aaaaaaa")
    DeployEvents::Inferrer.call(@managed_app)

    assert_equal 0, @managed_app.deploy_events.count
    assert_equal "aaaaaaa", @managed_app.reload.last_converged_version
  end

  test "有机器失联不算收敛" do
    converge(version: "aaaaaaa", at: 10.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)

    observe(host: "10.0.0.1", version: "bbbbbbb")
    observe(host: "10.0.0.2", version: nil, status: nil, reachable: false)
    DeployEvents::Inferrer.call(@managed_app)

    assert_equal 0, @managed_app.deploy_events.count,
                 "那台失联的机器可能还跑着旧版，面板并不知道"
    assert_equal "aaaaaaa", @managed_app.reload.last_converged_version
  end

  test "没有任何 running 观测不算收敛" do
    HOSTS.each { |host| observe(host: host, version: "aaaaaaa", status: "exited") }

    DeployEvents::Inferrer.call(@managed_app)

    assert_equal 0, @managed_app.deploy_events.count
    assert_nil @managed_app.reload.last_converged_version
  end

  test "同一版本连续多轮是幂等的" do
    converge(version: "aaaaaaa", at: 10.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)
    converge(version: "bbbbbbb", at: 5.minutes.ago)

    3.times { DeployEvents::Inferrer.call(@managed_app) }

    assert_equal 1, @managed_app.deploy_events.count,
                 "轮询在 burst 期是 2 秒一轮，不幂等的话历史会被同一次部署刷屏"
  end

  test "回滚到很久以前的版本仍然记一条" do
    # 那一版在三个月前部署过，库里躺着一条老的 hook 事件
    old_event = DeployEvent.create!(managed_app: @managed_app, version: "aaaaaaa",
                                    source: "hook", succeeded_at: 3.months.ago,
                                    observed_at: 3.months.ago, created_at: 3.months.ago)
    converge(version: "bbbbbbb", at: 10.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)

    # 现在回滚回 aaaaaaa
    converge(version: "aaaaaaa", at: 1.minute.ago)
    DeployEvents::Inferrer.call(@managed_app)

    inferred = @managed_app.deploy_events.where(source: "inferred", version: "aaaaaaa")
    assert_equal 1, inferred.count,
                 "只按 version 去重会把这次回滚吞掉——它明明是一次真实的部署"
    refute_equal old_event.id, inferred.sole.id
  end

  test "收敛期内已有同版本 hook 事件时让位，但状态照样更新" do
    converge(version: "aaaaaaa", at: 30.minutes.ago)
    DeployEvents::Inferrer.call(@managed_app)

    # hook 报了这一版，随后面板才观测到收敛
    DeployEvent.create!(managed_app: @managed_app, version: "bbbbbbb", source: "hook",
                        succeeded_at: 2.minutes.ago)
    converge(version: "bbbbbbb", at: 1.minute.ago)
    DeployEvents::Inferrer.call(@managed_app)

    assert_equal 0, @managed_app.deploy_events.where(source: "inferred").count
    assert_equal "bbbbbbb", @managed_app.reload.last_converged_version,
                 "让位不记事件，但状态必须更新，否则下一次变更会拿错误的时间边界去比"
  end
end
```

- [ ] **Step 2: 运行，确认失败**

Run: `timeout 600 bin/rails test test/services/deploy_events/inferrer_test.rb 2>&1 | tail -20`
Expected: FAIL —— `NameError: uninitialized constant DeployEvents::Inferrer`

- [ ] **Step 3: 迁移**

```bash
bin/rails generate migration AddConvergenceTrackingToManagedApps
```

内容替换为：

```ruby
class AddConvergenceTrackingToManagedApps < ActiveRecord::Migration[8.1]
  def change
    # nil 表示"还没建立基线"：第一次收敛只写这两列、不产生事件。
    # 一个早就在跑某一版的应用刚被接进面板，它不是"今天部署的"。
    add_column :managed_apps, :last_converged_version, :string
    # 存的是观测时刻（那批 running 观测里最早的 observed_at），不是 Time.current——
    # 与 Reconciler 回填 observed_at 用观测时间是同一条理由。
    add_column :managed_apps, :last_converged_at, :datetime
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 4: 放宽 SOURCES**

`app/models/deploy_event.rb`，把

```ruby
  SOURCES = %w[hook].freeze
```

改为

```ruby
  # inferred 是从 Observation 推断出来的（子设计 05）：面板只知道"版本变了"，
  # 给不出 performer / command，也看不见失败的部署。
  SOURCES = %w[hook inferred].freeze
```

- [ ] **Step 5: 实现 Inferrer**

`app/services/deploy_events/inferrer.rb`：

```ruby
module DeployEvents
  # 从观测推断部署事件（子设计 05）。
  #
  # 只在【全体收敛】时记一条：配置里每一台 host 都有可达且 running 的观测，
  # 且这些观测的 version 一致。滚动部署中途的混合版本不产生事件，一次部署一行。
  #
  # 有机器失联时不算收敛——那台机器可能还跑着旧版，面板并不知道。沉默比编造正确。
  class Inferrer
    RUNNING_STATUSES = %w[running restarting].freeze

    def self.call(managed_app)
      new(managed_app).call
    end

    def initialize(managed_app)
      @managed_app = managed_app
    end

    def call
      version, converged_at = converged_state
      return if version.nil?
      return if version == managed_app.last_converged_version

      # 比较用的是【更新之前】的边界：这条上报是不是在当前这一轮收敛期内到达的。
      record_inferred(version, converged_at) unless hook_already_reported?(version)

      # 让位不记事件时同样要更新——否则状态记着上一版，下一次真正的变更会拿
      # 一个错误的时间边界去比。
      managed_app.update_columns(last_converged_version: version,
                                 last_converged_at: converged_at,
                                 updated_at: Time.current)
    end

    private
      attr_reader :managed_app

      # => [version, converged_at] 或 [nil, nil]
      def converged_state
        rows = running_rows
        hosts = managed_app.cached_app_hosts

        # 每一台配置里的机器都要有可达且 running 的观测
        return [ nil, nil ] unless hosts.all? { |host| rows.any? { |o| o.host == host } }

        versions = rows.map(&:version).uniq
        return [ nil, nil ] unless versions.one?

        [ versions.first, rows.map(&:observed_at).min ]
      end

      def running_rows
        Observation.latest_for(managed_app).select do |o|
          o.reachable? && RUNNING_STATUSES.include?(o.docker_status) && o.version.present?
        end
      end

      def hook_already_reported?(version)
        boundary = managed_app.last_converged_at
        return false if boundary.nil?

        managed_app.deploy_events
                   .where(version: version)
                   .where(created_at: boundary..)
                   .exists?
      end

      def record_inferred(version, converged_at)
        # 基线：第一次收敛不产生事件。
        return if managed_app.last_converged_version.nil?

        managed_app.deploy_events.create!(
          version: version, source: "inferred",
          # 推断不出何时开始；performer / command 机器上看不出来，
          # 留空比编一个 "unknown" 诚实。
          started_at: nil, performer: nil, command: nil,
          succeeded_at: converged_at, observed_at: converged_at
        )
      end
  end
end
```

- [ ] **Step 6: 运行，确认通过**

Run: `timeout 600 bin/rails test test/services/deploy_events/inferrer_test.rb 2>&1 | tail -20`
Expected: 8 runs, 0 failures

- [ ] **Step 7: 全套并提交**

Run: `timeout 900 bin/rails test 2>&1 | tail -20`

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "feat: 从观测推断部署事件——只在全体收敛时记一条

滚动中途的混合版本不产生事件；有机器失联不算收敛（那台可能还跑着旧版）；
首次收敛只写基线——刚接入的应用不是今天部署的那一版。
去重带时间边界，否则回滚到很久以前的版本会被那条老事件静默吞掉。"
```

---

## Task 2: 接进轮询

**Files:**
- Modify: `app/jobs/poll_managed_app_job.rb`
- Test: `test/jobs/poll_managed_app_job_test.rb`

**Interfaces:**
- Consumes: `DeployEvents::Inferrer.call(managed_app)`（Task 1）。
- 现状：该作业里已有两个采集器与 `DeployEvents::Reconciler`，各自独立 `begin/rescue`，方法末尾 `raise error if error`。

- [ ] **Step 1: 写失败测试**

在 `test/jobs/poll_managed_app_job_test.rb` 中追加（该文件已存在，`class PollManagedAppJobTest < ExecutionLayerTest`，已有 `build_app` 与 `setup { FakeHost.start_proxy("node-1") }`——**复用现成的 `build_app`**，不要新建文件或另写夹具）：

```ruby
  test "一轮轮询会建立收敛基线，第二轮换版本后推断出一条部署" do
    app = build_app
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")

    PollManagedAppJob.perform_now(app)

    assert_equal "aaaaaaa", app.reload.last_converged_version
    assert_equal 0, app.deploy_events.count, "首次收敛只建基线"

    FakeHost.reset!("node-1")
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "bbbbbbb")

    PollManagedAppJob.perform_now(app)

    event = app.deploy_events.sole
    assert_equal "bbbbbbb", event.version
    assert_equal "inferred", event.source
  end
```

- [ ] **Step 2: 运行，确认失败**

Run: `timeout 900 bin/rails test test/jobs/poll_managed_app_job_test.rb 2>&1 | tail -20`
Expected: FAIL —— `last_converged_version` 为 nil（Inferrer 还没被调用）

- [ ] **Step 3: 挂上去**

`app/jobs/poll_managed_app_job.rb`：紧跟在调用 `DeployEvents::Reconciler` 的那个 `begin/rescue` 块之后插入：

```ruby
    begin
      # 顺序有讲究：Reconciler 先回填 hook 事件的 observed_at，Inferrer 才能
      # 看见"这一版刚被回填过"，从而让位不记重复的推断事件。
      DeployEvents::Inferrer.call(managed_app) unless parse_error
    rescue StandardError => e
      error ||= e
    end
```

- [ ] **Step 4: 运行，确认通过**

Run: `timeout 900 bin/rails test test/jobs/poll_managed_app_job_test.rb 2>&1 | tail -20`
Expected: 全绿

- [ ] **Step 5: 提交**

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "feat: 轮询里挂上 Inferrer，排在 Reconciler 之后

顺序不能反：推断要能看见 hook 事件刚被回填过，才谈得上让位。"
```

---

## Task 3: 界面区分两类事实

**Files:**
- Modify: `app/models/deploy_event.rb`（`observation_delay_text`）
- Modify: `app/views/managed_apps/_deploy_history.html.erb`
- Modify: `README.md`
- Test: `test/models/deploy_event_test.rb`、`test/system/deploy_history_test.rb`

**Interfaces:**
- Consumes: `DeployEvent#source`（Task 1 起可为 `"inferred"`）。
- Produces: `DeployEvent#source_text` → `"hook 上报"` 或 `"面板推断"`。

- [ ] **Step 1: 写失败测试（模型）**

在 `test/models/deploy_event_test.rb` 中追加：

```ruby
  test "推断事件的观测列不说延迟" do
    at = 5.minutes.ago
    event = DeployEvent.new(source: "inferred", version: "aaaaaaa",
                            succeeded_at: at, observed_at: at)

    assert_equal "面板观测到", event.observation_delay_text,
                 "推断事件没有上报，算出来的 0 秒是个没有含义的数字"
  end

  test "来源有文字说法" do
    assert_equal "hook 上报", DeployEvent.new(source: "hook").source_text
    assert_equal "面板推断", DeployEvent.new(source: "inferred").source_text
  end
```

- [ ] **Step 2: 运行，确认失败**

Run: `timeout 600 bin/rails test test/models/deploy_event_test.rb 2>&1 | tail -20`
Expected: FAIL —— `NoMethodError: undefined method 'source_text'`

- [ ] **Step 3: 实现**

`app/models/deploy_event.rb`，在 `observation_delay_text` 里最前面加一支，并新增 `source_text`：

```ruby
  def observation_delay_text
    # 推断事件根本没有上报，"延迟"无从谈起——succeeded_at 与 observed_at 都是
    # 收敛时刻，算出来的 0 秒是个没有含义的数字。
    return "面板观测到" if source == "inferred"

    return nil unless observed?
    return "未验证" unless succeeded_at

    delay = observation_delay
    return "上报前已观测到" if delay.nil? || delay <= 0

    "延迟 #{delay.round} 秒"
  end

  # 两类事实混在同一张表里，读的人必须一眼看出哪行是机器说的、哪行是面板推的。
  def source_text
    source == "inferred" ? "面板推断" : "hook 上报"
  end
```

- [ ] **Step 4: 运行，确认通过**

Run: `timeout 600 bin/rails test test/models/deploy_event_test.rb 2>&1 | tail -20`
Expected: 全绿

- [ ] **Step 5: 历史表加「来源」列**

`app/views/managed_apps/_deploy_history.html.erb`：表头那一行改为

```erb
      <tr><th>版本</th><th>来源</th><th>发起人</th><th>命令</th><th>开始</th><th>完成</th><th>观测</th></tr>
```

在版本那一格之后插入一格（文字，不靠颜色——项目硬约束）：

```erb
          <td><%= event.source_text %></td>
```

- [ ] **Step 6: 空状态文案改对**

同一文件，把现在这段

```erb
    还没收到任何上报。
    <% if managed_app.hook_reporting_enabled? %>
```

改成（保留原有的两条分支内容不动，只改这句总述并补上推断这一路）：

```erb
    还没有部署记录。这里有两个来源：面板每轮轮询都会比对各机器上正在跑的版本，
    版本变了就记一条「面板推断」；配上部署上报之后，还能拿到发起人、命令，
    以及失败的部署。
    <% if managed_app.hook_reporting_enabled? %>
```

- [ ] **Step 7: 写系统测试**

在 `test/system/deploy_history_test.rb` 中追加：

```ruby
  test "两种来源的行各自显示正确的文字" do
    at = 5.minutes.ago
    DeployEvent.create!(managed_app: @managed_app, version: "aaaaaaa", source: "hook",
                        performer: "ci-bot", command: "deploy",
                        succeeded_at: at, observed_at: at + 30.seconds)
    DeployEvent.create!(managed_app: @managed_app, version: "bbbbbbb", source: "inferred",
                        succeeded_at: at, observed_at: at)

    visit managed_app_path(@managed_app)

    assert_text "hook 上报"
    assert_text "面板推断"
    assert_text "面板观测到"
  end
```

注意该文件里已有的用例用的是哪个实例变量名（`@managed_app` 还是别的），照抄现成写法，不要引入新名字。

- [ ] **Step 8: README 补一段**

`README.md` 的 "Deploy reporting (optional)" 一节末尾追加：

```markdown
Even without the hooks you get *some* history: every poll compares the version running on
each host, and when all of them converge on a version different from the last one, the
panel records that as an inferred deployment. That gives you "something was deployed, and
when" — but not who did it, not the command, and not failed deploys, since a failed deploy
leaves the running version unchanged. Those three only come from the hooks.
```

- [ ] **Step 9: 两段跑全套并提交**

Run: `timeout 900 bin/rails test 2>&1 | tail -20`
Run: `timeout 900 bin/rails test:system 2>&1 | tail -20`

```bash
bin/rubocop && bin/brakeman -q
git add -A
git commit -m "feat: 部署历史区分 hook 上报与面板推断

两类事实混在一张表里，读的人必须一眼看出哪行是机器说的、哪行是面板推的。
推断行的观测列不说延迟——它没有上报，0 秒是个没有含义的数字。"
```

---

## 自查记录

**Spec 覆盖检查：**

| 子设计章节 | 覆盖任务 |
|---|---|
| 2 收敛的定义（每台可达 running、多角色、不要求新鲜、收敛时刻取最早） | Task 1（`converged_state` / `running_rows` 与四条测试） |
| 3 状态与去重（基线、幂等、让位、时间边界用更新前的值、让位也更新） | Task 1（后四条测试逐条对应） |
| 4 推断事件的字段取值 | Task 1 Step 5 与「收敛版本变化」那条测试的逐字段断言 |
| 5 触发点与顺序 | Task 2 |
| 5 呈现（来源列、观测列、空状态、README） | Task 3 |
| 6 已知限制 | 无需代码；README 那段说明了三条中的两条（给不出 performer/command、看不见失败部署） |
| 7 测试策略 | Task 1 六情形（拆成八条用例）、Task 2 链路、Task 3 system |

**未覆盖（属后续轮次）：** 深色模式。

**类型一致性：** `DeployEvents::Inferrer.call(managed_app)` 在 Task 1 定义、Task 2 使用；`ManagedApp#last_converged_version` / `#last_converged_at` 在 Task 1 建列、Task 1 与 Task 2 的测试断言；`DeployEvent#source_text` 在 Task 3 定义并在同任务视图与 system 测试中消费；`observation_delay_text` 的新分支与既有三支共存，Task 3 Step 3 给的是完整方法体，不是补丁片段。

**占位符扫描：** 无 TBD / TODO /「类似 Task N」。Task 3 Step 7 要求先看该测试文件现有的实例变量名再落笔——那是「按现成写法走」的指令，不是待填空白。
