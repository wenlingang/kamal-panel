# kamal-panel 实施计划 01：地基与只读链路

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建成一个**只读**的 kamal-panel：能接入 Application（粘贴 deploy.yml）、通过 SSH 采集真实容器与路由状态、在总览页呈现版本漂移／容器异常／机器失联，且所有执行层测试跑在真实 SSH 的 fake host 上。

**Architecture:** Rails 8 单体应用，直接 `require "kamal"` 复用其配置解析与命令生成，用 SSHKit 连接用户自己 deploy.yml 里声明的 SSH 参数。机器是唯一真相来源，数据库只存不可变的 Observation 快照。deploy.yml 解析在受限子进程中进行（Kamal 会对其做 ERB 求值）。

**Tech Stack:** Ruby 4.0 / Rails 8.1 / kamal gem 2.12 / SSHKit / SQLite / Solid Queue / Solid Cable / Hotwire（Turbo + Stimulus）/ Minitest + Capybara / Docker Compose（测试用 fake host）

**Spec:** `docs/superpowers/specs/2026-09-05-kamal-panel-design.md`

## Global Constraints

这些是全局约束，**每个任务的要求都隐含包含本节**：

- **仅支持 Kamal 2+**，不支持 1.x。验证基线：kamal **v2.12.0**、kamal-proxy **v0.10.0**。
- **不引入 Redis**：后台任务用 Solid Queue，实时推送用 Solid Cable。
- **不引入任何前端框架**：只用 Hotwire（Turbo + Stimulus）。
- **不实现任何形式的远程 shell**（`kamal app exec`、任意命令输入框等）。这是 spec 2.2 的硬性 non-goal。
- **本计划范围内不实现任何写操作**：不做 rollback / restart / stop。只读链路先跑通。
- **禁止 mock SSH**（spec 9.1）。执行层测试必须连真实 fake host。
- **`Kamal::Configuration.create_from` 必须显式传 `version:`**：否则 `config.version` 会回落到 `git_version` 去 shell 调 git，而面板环境中不存在用户应用的 git 仓库。
- **解析 deploy.yml 等于执行任意 Ruby**（Kamal 对其做 ERB 求值 + `YAML.unsafe_load`）。所有解析必须走受限子进程（spec 7.6）。
- **Observation 只追加**：任何代码都不得 `UPDATE` 已有的 Observation 行。
- 容器名格式固定为 `service-role-destination-VERSION`（`Kamal::Configuration::Role#container_name`）。
- 状态色只有四种（漂移／异常／失联／正常），且**状态绝不能只靠颜色传达**，必须同时有文字或形状标识。
- **本文件中所有 deploy.yml 示例都缺 `builder:` 段，而 Kamal 2.12.0 的校验器硬性要求它。** 任何测试 fixture 或内联 YAML 都必须补上：

  ```yaml
  builder:
    arch: amd64
  ```

  这一点在 Task 3、6、7、9 各绊了一次。照抄本文件的 YAML 时请一律补齐，不要每个任务重新发现它。

## 后续计划（不在本文件范围）

- **计划 02：操作与安全** —— User/角色/登录、AuditLog、封闭动作集、Kamal 锁的获取与展示、rollback/restart/stop、执行过程流式输出、强制解锁。
- **计划 03：Hook 链路与发布** —— DeployEvent 接收端点、per-application token、两套数据源对账告警、深色模式、Kamal 版本兼容矩阵 CI、自部署 deploy.yml、README。

计划 01 完成后即为一个可用的只读面板，可独立验收。

---

## 文件结构

```
kamal-panel/
├── app/
│   ├── models/
│   │   ├── application_record.rb
│   │   ├── managed_app.rb              # 被管应用（表名 managed_apps，避开 Rails 保留名）
│   │   ├── credential.rb               # 加密存储的 SSH 私钥
│   │   ├── observation.rb              # 不可变观测快照
│   │   └── proxy_target.rb             # kamal-proxy 路由表快照
│   ├── models/kamal/
│   │   ├── config_parser.rb            # 调用受限子进程解析 deploy.yml
│   │   └── parsed_config.rb            # 解析结果的值对象（不落库）
│   ├── services/collectors/
│   │   ├── ssh_session.rb              # SSHKit 封装，从 deploy.yml 取连接参数
│   │   ├── container_collector.rb      # docker ps --all → Observation
│   │   └── proxy_collector.rb          # kamal-proxy list --json → ProxyTarget
│   ├── services/managed_app_status.rb  # 由 Observation 计算应用状态（含版本漂移）
│   ├── jobs/
│   │   ├── poll_managed_app_job.rb
│   │   └── prune_observations_job.rb
│   ├── controllers/
│   │   ├── overviews_controller.rb
│   │   └── managed_apps_controller.rb
│   └── views/...
├── bin/parse_deploy_config             # 受限子进程入口（独立 ruby 脚本）
├── test/
│   ├── fake_host/                      # Dockerfile / entrypoint / 测试密钥
│   ├── support/fake_host_helper.rb
│   └── ...
├── docker-compose.test.yml
└── docs/superpowers/{specs,plans}/
```

**命名说明：** 领域上叫「Application」，但 Rails 里 `Application` 与 `Rails::Application` 冲突，因此模型名为 `ManagedApp`，表名 `managed_apps`，UI 文案仍称「应用」。

---

## Task 1: Rails 骨架与 kamal gem 接入

**Files:**
- Create: 整个 Rails 应用骨架（`rails new` 生成）
- Modify: `Gemfile`
- Create: `test/models/kamal_gem_availability_test.rb`
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: 无
- Produces: 可启动的 Rails 应用；`require "kamal"` 在应用进程内可用

- [ ] **Step 1: 生成 Rails 应用**

在仓库根目录（已有 `docs/` 与 `.git/`）执行：

```bash
cd /Users/wen/github/kamal-panel
gem install rails -v 8.1.3.1
rails new . --name=kamal_panel --database=sqlite3 --skip-jbuilder --skip-git --force
```

`--force` 用于允许在已有 `docs/` 的目录中生成；`--skip-git` 保留既有 git 历史。

- [ ] **Step 2: 把 kamal 移入主依赖组**

`rails new` 生成的 Gemfile 把 kamal 放在 `group :development`。面板需要在运行时使用它，必须移到主组。编辑 `Gemfile`：

删除 development 组里的 `gem "kamal", require: false`，在主组加入：

```ruby
# Kamal 是本项目的核心依赖：直接复用其配置解析与命令生成。
# require: false 是刻意的——kamal 会加载 Thor CLI，我们只在需要时局部 require。
gem "kamal", "~> 2.12"
```

然后：

```bash
bundle install
```

- [ ] **Step 3: 写失败测试——确认 kamal 可在应用内加载且版本符合最低要求**

`test/models/kamal_gem_availability_test.rb`：

```ruby
require "test_helper"

class KamalGemAvailabilityTest < ActiveSupport::TestCase
  test "kamal gem 可以在应用进程内加载" do
    require "kamal"
    assert defined?(Kamal::Configuration)
  end

  test "kamal 版本不低于 2.12（本项目的验证基线）" do
    require "kamal"
    assert_operator Gem::Version.new(Kamal::VERSION), :>=, Gem::Version.new("2.12.0"),
      "本项目依赖 v2.12.0 中确认的 Kamal 内部行为，见 spec 第 4 节"
  end
end
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `bin/rails test test/models/kamal_gem_availability_test.rb`
Expected: 2 runs, 2 assertions, 0 failures

若第一个测试报 `LoadError`，说明 Step 2 的 Gemfile 修改没生效。

- [ ] **Step 5: 建立 CI**

`.github/workflows/ci.yml`：

```yaml
name: CI

on:
  push:
    branches: [ main ]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - name: 单元测试
        run: bin/rails test
```

（连 fake host 的执行层测试将在 Task 2 加入 CI。）

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat: Rails 8 骨架，kamal gem 进主依赖组

kamal 放在主组而非 development 组：面板在运行时需要它的
Configuration 解析与 Commands 生成。保留 require: false，
避免启动时加载 Thor CLI。"
```

---

## Task 2: fake host 测试夹具（硬前置）

**Files:**
- Create: `test/fake_host/Dockerfile`
- Create: `test/fake_host/entrypoint.sh`
- Create: `test/fake_host/id_ed25519`、`test/fake_host/id_ed25519.pub`
- Create: `docker-compose.test.yml`
- Create: `test/support/fake_host_helper.rb`
- Create: `test/support/fake_host_smoke_test.rb`
- Modify: `test/test_helper.rb`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: 无
- Produces:
  - `FakeHost::NODES` → `{ "node-1" => 2201, "node-2" => 2202 }`
  - `FakeHost.private_key` → String（PEM 内容）
  - `FakeHost.ssh(node_name, command)` → String（stdout）
  - `FakeHost.seed_container(node:, service:, role:, destination:, version:, state: :running)` → String（容器名）
  - `FakeHost.reset!(node)` → void
  - `FakeHost.ready?` → Boolean

**这是 spec 9.6 的硬前置：本任务必须在任何执行层测试之前完成。** 否则第一个执行层测试会退化成 mock，此后再也回不来。

- [ ] **Step 1: 生成测试专用 SSH 密钥对**

```bash
mkdir -p test/fake_host
ssh-keygen -t ed25519 -N "" -C "kamal-panel test fixture" -f test/fake_host/id_ed25519
```

在 `test/fake_host/README.md` 写明：

```markdown
# 测试夹具密钥

本目录中的 `id_ed25519` 是**故意提交进仓库的测试密钥**，仅用于本地与 CI 中的
fake host 容器。它不保护任何真实资产。

请勿将其用于任何真实服务器。
```

- [ ] **Step 2: 编写 fake host 镜像**

fake host 必须运行**自己独立的 Docker daemon**（dind），而不是复用宿主的。原因：只有每台 fake host 拥有独立的容器集合，才能构造出「node-1 跑 v3、node-2 跑 v2」的版本漂移场景。

`test/fake_host/Dockerfile`：

```dockerfile
FROM docker:29-dind

RUN apk add --no-cache openssh-server

RUN ssh-keygen -A \
 && adduser -D -s /bin/sh deploy \
 && addgroup deploy docker \
 && passwd -u deploy \
 && mkdir -p /home/deploy/.ssh

COPY id_ed25519.pub /home/deploy/.ssh/authorized_keys

RUN chown -R deploy:deploy /home/deploy/.ssh \
 && chmod 700 /home/deploy/.ssh \
 && chmod 600 /home/deploy/.ssh/authorized_keys

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
```

`test/fake_host/entrypoint.sh`：

```sh
#!/bin/sh
set -e

# 后台启动 dockerd（dind 镜像自带的入口脚本）
dockerd-entrypoint.sh dockerd >/var/log/dockerd.log 2>&1 &

# 等待 docker socket 就绪
for i in $(seq 1 60); do
  if [ -S /var/run/docker.sock ]; then
    break
  fi
  sleep 1
done

if [ ! -S /var/run/docker.sock ]; then
  echo "dockerd 启动超时" >&2
  cat /var/log/dockerd.log >&2
  exit 1
fi

# 让 deploy 用户可以访问 docker socket
chgrp docker /var/run/docker.sock
chmod 660 /var/run/docker.sock

# 预拉测试用镜像，避免每个测试各拉一次
docker pull busybox:latest >/dev/null 2>&1 || true

exec /usr/sbin/sshd -D -e
```

- [ ] **Step 3: 编写 compose 文件**

`docker-compose.test.yml`：

```yaml
services:
  node-1:
    build: ./test/fake_host
    privileged: true          # dind 必需
    ports:
      - "2201:22"
  node-2:
    build: ./test/fake_host
    privileged: true
    ports:
      - "2202:22"
```

- [ ] **Step 4: 启动并手工验证**

```bash
docker compose -f docker-compose.test.yml up -d --build
ssh -i test/fake_host/id_ed25519 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -p 2201 deploy@127.0.0.1 'docker ps'
```

Expected: 输出 docker ps 的表头（空列表），无报错。若报 `permission denied` 访问 socket，说明 entrypoint 的 chgrp 没生效。

- [ ] **Step 5: 编写测试助手**

`test/support/fake_host_helper.rb`：

```ruby
require "net/ssh"

module FakeHost
  NODES = { "node-1" => 2201, "node-2" => 2202 }.freeze
  KEY_PATH = Rails.root.join("test/fake_host/id_ed25519")

  class NotReady < StandardError; end

  def self.private_key
    File.read(KEY_PATH)
  end

  def self.ssh_options
    {
      keys: [ KEY_PATH.to_s ],
      keys_only: true,
      auth_methods: [ "publickey" ],
      verify_host_key: :never,
      timeout: 5
    }
  end

  def self.ssh(node, command)
    port = NODES.fetch(node)
    Net::SSH.start("127.0.0.1", "deploy", **ssh_options, port: port) do |session|
      session.exec!(command).to_s
    end
  end

  def self.ready?
    NODES.each_key { |node| ssh(node, "docker info >/dev/null && echo ok") }
    true
  rescue StandardError
    false
  end

  def self.ensure_ready!
    return if ready?

    raise NotReady, <<~MSG
      fake host 未就绪。请先启动：
        docker compose -f docker-compose.test.yml up -d --build
    MSG
  end

  # 按 Kamal 的命名与标签约定造一个容器。
  # 容器名格式来自 Kamal::Configuration::Role#container_name:
  #   [service, role, destination].compact.join("-") + "-" + version
  def self.seed_container(node:, service:, role:, destination:, version:, state: :running)
    name = [ service, role, destination, version ].compact.join("-")

    ssh node, <<~SH
      docker run -d --name #{name} \
        --label service=#{service} \
        --label destination=#{destination} \
        --label role=#{role} \
        busybox:latest sleep 3600
    SH

    ssh(node, "docker stop #{name}") if state == :stopped

    name
  end

  def self.reset!(node)
    ssh node, "docker ps -aq | xargs -r docker rm -f"
  end

  def self.reset_all!
    NODES.each_key { |node| reset!(node) }
  end
end
```

- [ ] **Step 6: 接入 test_helper**

在 `test/test_helper.rb` 中加入：

```ruby
require "support/fake_host_helper"

# 需要真实 SSH 的测试继承这个基类。
# 它保证 fake host 就绪，并在每个测试前清空容器。
class ExecutionLayerTest < ActiveSupport::TestCase
  setup do
    FakeHost.ensure_ready!
    FakeHost.reset_all!
  end
end
```

并确保 `test/` 在 load path 中（Rails 默认已包含，如报 LoadError 则在 test_helper 顶部加 `$LOAD_PATH.unshift(File.expand_path(".", __dir__))`）。

- [ ] **Step 7: 写夹具自检测试**

`test/support/fake_host_smoke_test.rb`：

```ruby
require "test_helper"

class FakeHostSmokeTest < ExecutionLayerTest
  test "两台 fake host 都能 SSH 进去并执行 docker" do
    FakeHost::NODES.each_key do |node|
      assert_match(/Server:/, FakeHost.ssh(node, "docker version"))
    end
  end

  test "每台 fake host 有独立的 docker daemon" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")

    on_node_1 = FakeHost.ssh("node-1", "docker ps --format '{{.Names}}'")
    on_node_2 = FakeHost.ssh("node-2", "docker ps --format '{{.Names}}'")

    assert_includes on_node_1, "blog-web-production-aaaaaaa"
    refute_includes on_node_2, "blog-web-production-aaaaaaa"
  end

  test "可以造出已停止的容器" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "bbbbbbb",
                            state: :stopped)

    running = FakeHost.ssh("node-1", "docker ps --format '{{.Names}}'")
    all     = FakeHost.ssh("node-1", "docker ps -a --format '{{.Names}}'")

    refute_includes running, "blog-web-production-bbbbbbb"
    assert_includes all, "blog-web-production-bbbbbbb"
  end
end
```

- [ ] **Step 8: 运行测试**

Run: `bin/rails test test/support/fake_host_smoke_test.rb`
Expected: 3 runs, 0 failures

第二个测试是本任务的关键断言：**它证明了版本漂移场景可以被真实构造**。如果它失败（node-2 也看到了 node-1 的容器），说明 dind 没生效、两台共用了宿主 daemon，后续所有漂移测试都将失去意义。

- [ ] **Step 9: 加入 CI**

在 `.github/workflows/ci.yml` 的 `test` job 中，`单元测试` 步骤**之前**插入：

```yaml
      - name: 启动 fake host
        run: docker compose -f docker-compose.test.yml up -d --build
      - name: 等待 fake host 就绪
        run: |
          for i in $(seq 1 60); do
            if ssh -i test/fake_host/id_ed25519 -o StrictHostKeyChecking=no \
                   -o UserKnownHostsFile=/dev/null -p 2201 deploy@127.0.0.1 \
                   'docker info' >/dev/null 2>&1; then
              echo "ready"; exit 0
            fi
            sleep 2
          done
          echo "fake host 启动超时"; exit 1
```

- [ ] **Step 10: 提交**

```bash
git add -A
git commit -m "test: fake host 夹具（真实 SSH + 每台独立 dind）

这是 spec 9.6 规定的硬前置：必须在第一个执行层测试之前就位，
否则测试会退化成 mock。

每台 fake host 跑自己的 docker daemon，这样才能构造
「node-1 跑 v3、node-2 跑 v2」的版本漂移场景。"
```

---

## Task 3: deploy.yml 受限子进程解析

**Files:**
- Create: `bin/parse_deploy_config`
- Create: `app/models/kamal/parsed_config.rb`
- Create: `app/models/kamal/config_parser.rb`
- Create: `test/fixtures/files/simple_deploy.yml`
- Create: `test/models/kamal/config_parser_test.rb`

**Interfaces:**
- Consumes: kamal gem（Task 1）
- Produces:
  - `Kamal::ConfigParser.call(yaml:, destination: nil)` → `Kamal::ParsedConfig`（成功）或抛 `Kamal::ConfigParser::ParseError`
  - `Kamal::ParsedConfig#service` → String
  - `Kamal::ParsedConfig#destination` → String / nil
  - `Kamal::ParsedConfig#roles` → Array<Hash> 每项 `{ name:, hosts:, container_prefix: }`
  - `Kamal::ParsedConfig#app_hosts` → Array<String>
  - `Kamal::ParsedConfig#primary_host` → String
  - `Kamal::ParsedConfig#registry_server` → String / nil
  - `Kamal::ParsedConfig#ssh_options` → Hash（`user:`、`port:`、`proxy:`）

**为什么必须是子进程：** Kamal 的 `load_config_file` 对 deploy.yml 做 `ERB.new(...).result` 再 `YAML.unsafe_load`。解析一份用户粘贴的 deploy.yml 等价于在面板进程中执行任意 Ruby（spec 7.6）。

- [ ] **Step 1: 写解析子进程脚本**

`bin/parse_deploy_config`：

```ruby
#!/usr/bin/env ruby
# 从 stdin 读 JSON: {"yaml": "...", "destination": "production"|null}
# 向 stdout 写 JSON: {"ok": true, ...} 或 {"ok": false, "error": "..."}
#
# 本脚本在独立子进程中运行，因为 Kamal 解析 deploy.yml 时会做 ERB 求值
# 与 YAML.unsafe_load，两者都是任意代码执行路径。见 spec 7.6。

require "json"
require "tempfile"

def emit(hash)
  $stdout.write(JSON.generate(hash))
  $stdout.flush
end

begin
  input = JSON.parse($stdin.read)

  require "kamal"

  Tempfile.create([ "deploy", ".yml" ]) do |file|
    file.write(input.fetch("yaml"))
    file.flush

    # version 必须显式传入：否则 Kamal::Configuration#version 会回落到
    # git_version，去 shell 调 git —— 面板环境里没有用户应用的 git 仓库。
    config = Kamal::Configuration.create_from(
      config_file: file.path,
      destination: input["destination"],
      version: "unused-by-parsing"
    )

    emit(
      ok: true,
      service: config.service,
      destination: config.destination,
      roles: config.roles.map { |role|
        { name: role.name, hosts: role.hosts, container_prefix: role.container_prefix }
      },
      app_hosts: config.app_hosts,
      primary_host: config.primary_host,
      registry_server: config.registry.server,
      ssh_options: {
        user: config.ssh.user,
        port: config.ssh.port,
        proxy: config.ssh.proxy&.to_s
      }
    )
  end
rescue StandardError => e
  emit(ok: false, error: "#{e.class}: #{e.message}")
end
```

```bash
chmod +x bin/parse_deploy_config
```

- [ ] **Step 2: 写测试夹具 deploy.yml**

`test/fixtures/files/simple_deploy.yml`：

```yaml
service: blog
image: example/blog

servers:
  web:
    - 127.0.0.1
  worker:
    hosts:
      - 127.0.0.1
    cmd: bin/jobs

registry:
  server: registry.example.com
  username: someone
  password:
    - KAMAL_REGISTRY_PASSWORD

ssh:
  user: deploy
  port: 2201

proxy:
  host: blog.example.com
```

- [ ] **Step 3: 写失败测试**

`test/models/kamal/config_parser_test.rb`：

```ruby
require "test_helper"

class Kamal::ConfigParserTest < ActiveSupport::TestCase
  def simple_yaml
    file_fixture("simple_deploy.yml").read
  end

  test "解析出服务名、角色与主机" do
    parsed = Kamal::ConfigParser.call(yaml: simple_yaml, destination: "production")

    assert_equal "blog", parsed.service
    assert_equal "production", parsed.destination
    assert_equal %w[web worker], parsed.roles.map { |r| r[:name] }.sort
    assert_equal [ "127.0.0.1" ], parsed.app_hosts
    assert_equal "registry.example.com", parsed.registry_server
  end

  test "容器名前缀含 destination，与 Kamal 的约定一致" do
    parsed = Kamal::ConfigParser.call(yaml: simple_yaml, destination: "production")
    web = parsed.roles.detect { |r| r[:name] == "web" }

    assert_equal "blog-web-production", web[:container_prefix]
  end

  test "沿用 deploy.yml 里声明的 SSH 参数" do
    parsed = Kamal::ConfigParser.call(yaml: simple_yaml, destination: "production")

    assert_equal "deploy", parsed.ssh_options[:user]
    assert_equal 2201, parsed.ssh_options[:port]
  end

  test "无效 YAML 抛 ParseError 而非崩溃" do
    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: "这不是合法的 deploy 配置")
    end

    assert_match(/./, error.message)
  end

  test "解析在子进程中进行：deploy.yml 中的 ERB 无法污染面板进程" do
    malicious = <<~YAML
      service: evil
      image: example/evil
      <%= Object.const_set(:PANEL_WAS_COMPROMISED, true) %>
      servers:
        web:
          - 127.0.0.1
    YAML

    # 解析成功与否不重要，重要的是常量没有出现在本进程里
    begin
      Kamal::ConfigParser.call(yaml: malicious)
    rescue Kamal::ConfigParser::ParseError
      # 允许
    end

    refute defined?(::PANEL_WAS_COMPROMISED),
      "ERB 在面板进程内被求值了——解析没有真正隔离到子进程"
  end

  test "解析超时被当作失败处理" do
    slow = <<~YAML
      service: slow
      image: example/slow
      <%= sleep 30 %>
      servers:
        web:
          - 127.0.0.1
    YAML

    assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: slow, timeout: 2)
    end
  end
end
```

- [ ] **Step 4: 运行测试，确认失败**

Run: `bin/rails test test/models/kamal/config_parser_test.rb`
Expected: FAIL —— `NameError: uninitialized constant Kamal::ConfigParser`

- [ ] **Step 5: 实现值对象**

`app/models/kamal/parsed_config.rb`：

```ruby
# Kamal 命名空间下的值对象。不落库——deploy.yml 是唯一真相，
# 解析结果每次现算（spec 5.1）。
class Kamal::ParsedConfig
  attr_reader :service, :destination, :roles, :app_hosts, :primary_host,
              :registry_server, :ssh_options

  def initialize(attributes)
    @service         = attributes.fetch("service")
    @destination     = attributes["destination"]
    @roles           = attributes.fetch("roles").map(&:symbolize_keys)
    @app_hosts       = attributes.fetch("app_hosts")
    @primary_host    = attributes["primary_host"]
    @registry_server = attributes["registry_server"]
    @ssh_options     = attributes.fetch("ssh_options").symbolize_keys
  end

  def role_names
    roles.map { |role| role[:name] }
  end

  def container_prefix_for(role_name)
    roles.detect { |role| role[:name] == role_name.to_s }&.fetch(:container_prefix)
  end
end
```

- [ ] **Step 6: 实现解析器**

`app/models/kamal/config_parser.rb`：

```ruby
require "open3"
require "json"

# 在受限子进程中解析 deploy.yml。
#
# 为什么不直接在进程内调 Kamal::Configuration.create_from：
# Kamal 会对 deploy.yml 做 ERB.new(...).result 再 YAML.unsafe_load，
# 两者都是任意代码执行。用户粘贴的 deploy.yml 是不可信输入。见 spec 7.6。
class Kamal::ConfigParser
  class ParseError < StandardError; end

  DEFAULT_TIMEOUT = 5.seconds
  SCRIPT = Rails.root.join("bin/parse_deploy_config").to_s

  def self.call(yaml:, destination: nil, timeout: DEFAULT_TIMEOUT)
    new(yaml:, destination:, timeout:).call
  end

  def initialize(yaml:, destination:, timeout:)
    @yaml = yaml
    @destination = destination
    @timeout = timeout
  end

  def call
    result = JSON.parse(run_subprocess)
    raise ParseError, result["error"] unless result["ok"]

    Kamal::ParsedConfig.new(result)
  rescue JSON::ParserError => e
    raise ParseError, "子进程返回了无法解析的输出：#{e.message}"
  end

  private
    attr_reader :yaml, :destination, :timeout

    def run_subprocess
      input = JSON.generate(yaml: yaml, destination: destination)
      stdout = nil

      Open3.popen3(RbConfig.ruby, SCRIPT) do |stdin, out, err, wait_thread|
        stdin.write(input)
        stdin.close

        unless wait_thread.join(timeout)
          Process.kill("KILL", wait_thread.pid)
          wait_thread.join
          raise ParseError, "解析超时（#{timeout} 秒）。deploy.yml 中可能有耗时的 ERB。"
        end

        stdout = out.read
        stderr = err.read

        if stdout.blank?
          raise ParseError, "解析子进程无输出。stderr: #{stderr.truncate(500)}"
        end
      end

      stdout
    end
end
```

- [ ] **Step 7: 运行测试，确认通过**

Run: `bin/rails test test/models/kamal/config_parser_test.rb`
Expected: 6 runs, 0 failures

- [ ] **Step 8: 提交**

```bash
git add -A
git commit -m "feat: deploy.yml 受限子进程解析

Kamal 对 deploy.yml 做 ERB 求值 + YAML.unsafe_load，粘贴一份
deploy.yml 等价于在面板进程执行任意 Ruby。解析因此隔离到独立
子进程，带 5 秒硬超时，只回传 JSON 结果。

测试中包含一条隔离性断言：ERB 里 const_set 的常量不得出现在
面板进程中。"
```

---

## Task 4: ManagedApp 模型与接入表单

**Files:**
- Create: `db/migrate/<ts>_create_managed_apps.rb`
- Create: `app/models/managed_app.rb`
- Create: `app/controllers/managed_apps_controller.rb`
- Create: `app/views/managed_apps/{index,new,show}.html.erb`
- Modify: `config/routes.rb`
- Create: `test/models/managed_app_test.rb`
- Create: `test/system/managed_app_onboarding_test.rb`

**Interfaces:**
- Consumes: `Kamal::ConfigParser.call`（Task 3）
- Produces:
  - `ManagedApp#parsed_config` → `Kamal::ParsedConfig`（带 memo）
  - `ManagedApp#app_hosts` → Array<String>
  - `ManagedApp#service` → String
  - `ManagedApp` 校验：`config_yaml` 必须能解析成功

- [ ] **Step 1: 建表**

```bash
bin/rails generate migration CreateManagedApps
```

编辑生成的迁移：

```ruby
class CreateManagedApps < ActiveRecord::Migration[8.1]
  def change
    create_table :managed_apps do |t|
      t.string :name, null: false
      t.text   :config_yaml, null: false
      t.string :destination
      t.timestamps
    end

    add_index :managed_apps, :name, unique: true
  end
end
```

```bash
bin/rails db:migrate
```

- [ ] **Step 2: 写失败测试**

`test/models/managed_app_test.rb`：

```ruby
require "test_helper"

class ManagedAppTest < ActiveSupport::TestCase
  def valid_yaml
    file_fixture("simple_deploy.yml").read
  end

  test "解析成功才能保存" do
    app = ManagedApp.new(name: "blog", config_yaml: valid_yaml, destination: "production")
    assert app.valid?
  end

  test "无法解析的 deploy.yml 被拒绝，并给出原因" do
    app = ManagedApp.new(name: "broken", config_yaml: "不是配置")

    refute app.valid?
    assert_match(/无法解析/, app.errors[:config_yaml].join)
  end

  test "暴露解析出的服务名与主机" do
    app = ManagedApp.create!(name: "blog", config_yaml: valid_yaml, destination: "production")

    assert_equal "blog", app.service
    assert_equal [ "127.0.0.1" ], app.app_hosts
  end

  test "解析结果在实例内被缓存，不重复开子进程" do
    app = ManagedApp.create!(name: "blog", config_yaml: valid_yaml, destination: "production")

    assert_same app.parsed_config, app.parsed_config
  end
end
```

- [ ] **Step 3: 运行测试，确认失败**

Run: `bin/rails test test/models/managed_app_test.rb`
Expected: FAIL —— `NameError: uninitialized constant ManagedApp`（迁移已建表但模型未定义）

- [ ] **Step 4: 实现模型**

`app/models/managed_app.rb`：

```ruby
# 一个 ManagedApp = 一份 deploy.yml + 一个 destination（spec 5.5）。
# 同一 repo 部署到 staging 与 production 是两个 ManagedApp。
#
# 领域上称「应用」；模型名避开 Application 以免与 Rails::Application 冲突。
class ManagedApp < ApplicationRecord
  validates :name, presence: true, uniqueness: true
  validates :config_yaml, presence: true
  validate :config_yaml_must_parse

  def parsed_config
    @parsed_config ||= Kamal::ConfigParser.call(yaml: config_yaml, destination: destination)
  end

  def service
    parsed_config.service
  end

  def app_hosts
    parsed_config.app_hosts
  end

  def role_names
    parsed_config.role_names
  end

  # config_yaml 变更后必须让缓存失效，否则会拿旧解析结果去连新机器
  def config_yaml=(value)
    @parsed_config = nil
    super
  end

  def destination=(value)
    @parsed_config = nil
    super
  end

  private
    def config_yaml_must_parse
      return if config_yaml.blank?

      parsed_config
    rescue Kamal::ConfigParser::ParseError => e
      errors.add(:config_yaml, "无法解析：#{e.message}")
    end
end
```

- [ ] **Step 5: 运行测试，确认通过**

Run: `bin/rails test test/models/managed_app_test.rb`
Expected: 4 runs, 0 failures

- [ ] **Step 6: 路由与控制器**

`config/routes.rb` 加入：

```ruby
  resources :managed_apps, path: "apps", only: [ :index, :new, :create, :show ]
  root "managed_apps#index"
```

`app/controllers/managed_apps_controller.rb`：

```ruby
class ManagedAppsController < ApplicationController
  def index
    @managed_apps = ManagedApp.order(:name)
  end

  def show
    @managed_app = ManagedApp.find(params[:id])
  end

  def new
    @managed_app = ManagedApp.new
  end

  def create
    @managed_app = ManagedApp.new(managed_app_params)

    if @managed_app.save
      redirect_to @managed_app, notice: "已接入 #{@managed_app.service}"
    else
      render :new, status: :unprocessable_entity
    end
  end

  private
    def managed_app_params
      params.expect(managed_app: [ :name, :config_yaml, :destination ])
    end
end
```

- [ ] **Step 7: 视图**

`app/views/managed_apps/new.html.erb`：

```erb
<h1>接入一个应用</h1>

<p class="warning">
  粘贴 deploy.yml 会由 Kamal 解析，而 Kamal 会对其做 ERB 求值。
  只粘贴你信任的配置文件。
</p>

<%= form_with model: @managed_app do |form| %>
  <% if @managed_app.errors.any? %>
    <ul class="errors">
      <% @managed_app.errors.full_messages.each do |message| %>
        <li><%= message %></li>
      <% end %>
    </ul>
  <% end %>

  <div>
    <%= form.label :name, "名称" %>
    <%= form.text_field :name %>
  </div>

  <div>
    <%= form.label :destination, "Destination（可留空）" %>
    <%= form.text_field :destination %>
  </div>

  <div>
    <%= form.label :config_yaml, "deploy.yml 原文" %>
    <%= form.text_area :config_yaml, rows: 20 %>
  </div>

  <%= form.submit "解析并接入" %>
<% end %>
```

`app/views/managed_apps/show.html.erb`：

```erb
<h1><%= @managed_app.name %></h1>

<dl>
  <dt>服务名</dt>          <dd><%= @managed_app.service %></dd>
  <dt>Destination</dt>     <dd><%= @managed_app.destination || "（无）" %></dd>
  <dt>Registry</dt>        <dd><%= @managed_app.parsed_config.registry_server %></dd>
</dl>

<h2>解析出的角色</h2>
<table>
  <thead><tr><th>角色</th><th>主机</th><th>容器名前缀</th></tr></thead>
  <tbody>
    <% @managed_app.parsed_config.roles.each do |role| %>
      <tr>
        <td><%= role[:name] %></td>
        <td><%= role[:hosts].join(", ") %></td>
        <td><code><%= role[:container_prefix] %></code></td>
      </tr>
    <% end %>
  </tbody>
</table>
```

`app/views/managed_apps/index.html.erb`：

```erb
<h1>应用</h1>
<%= link_to "接入一个应用", new_managed_app_path %>

<ul>
  <% @managed_apps.each do |app| %>
    <li><%= link_to app.name, app %> — <%= app.app_hosts.size %> 台机器</li>
  <% end %>
</ul>
```

- [ ] **Step 8: 写系统测试**

`test/system/managed_app_onboarding_test.rb`：

```ruby
require "application_system_test_case"

class ManagedAppOnboardingTest < ApplicationSystemTestCase
  test "粘贴 deploy.yml 后当场看到解析出的角色与主机" do
    visit new_managed_app_path

    fill_in "名称", with: "blog"
    fill_in "Destination（可留空）", with: "production"
    fill_in "deploy.yml 原文", with: file_fixture("simple_deploy.yml").read
    click_on "解析并接入"

    assert_text "已接入 blog"
    assert_text "blog-web-production"
    assert_text "registry.example.com"
  end

  test "无法解析时留在表单页并说明原因" do
    visit new_managed_app_path

    fill_in "名称", with: "broken"
    fill_in "deploy.yml 原文", with: "不是配置"
    click_on "解析并接入"

    assert_text "无法解析"
  end
end
```

- [ ] **Step 9: 运行全部测试**

Run: `bin/rails test:all`
Expected: 全绿

- [ ] **Step 10: 提交**

```bash
git add -A
git commit -m "feat: ManagedApp 模型与接入表单

deploy.yml 里已有的 servers/roles/registry 一律不落库为字段，
每次现解析（spec 5.1）。config_yaml 或 destination 变更时清空
解析缓存，避免拿旧配置去连新机器。"
```

---

## Task 5: 加密存储的 SSH 凭据

**Files:**
- Create: `db/migrate/<ts>_create_credentials.rb`
- Create: `db/migrate/<ts>_add_ssh_credential_to_managed_apps.rb`
- Create: `app/models/credential.rb`
- Modify: `app/models/managed_app.rb`
- Modify: `app/controllers/managed_apps_controller.rb`
- Modify: `app/views/managed_apps/{new,show}.html.erb`
- Create: `test/models/credential_test.rb`

**Interfaces:**
- Consumes: `ManagedApp`（Task 4）
- Produces:
  - `Credential#value` → String（解密后的私钥 PEM）
  - `Credential#fingerprint` → String（可安全展示的指纹）
  - `ManagedApp#ssh_credential` → Credential / nil

- [ ] **Step 1: 初始化 ActiveRecord 加密**

```bash
bin/rails db:encryption:init
```

把输出的三个 key 写入 `config/credentials.yml.enc`（`bin/rails credentials:edit`）。

在 `config/application.rb` 中加入：

```ruby
    # 生产环境从环境变量读取加密主密钥，不落盘（spec 7.2）
    config.active_record.encryption.primary_key = ENV["AR_ENCRYPTION_PRIMARY_KEY"] if ENV["AR_ENCRYPTION_PRIMARY_KEY"]
    config.active_record.encryption.deterministic_key = ENV["AR_ENCRYPTION_DETERMINISTIC_KEY"] if ENV["AR_ENCRYPTION_DETERMINISTIC_KEY"]
    config.active_record.encryption.key_derivation_salt = ENV["AR_ENCRYPTION_KEY_DERIVATION_SALT"] if ENV["AR_ENCRYPTION_KEY_DERIVATION_SALT"]
```

- [ ] **Step 2: 建表**

```bash
bin/rails generate migration CreateCredentials
bin/rails generate migration AddSshCredentialToManagedApps
```

`CreateCredentials`：

```ruby
class CreateCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :credentials do |t|
      t.string :kind, null: false, default: "ssh_key"
      t.text   :value, null: false      # 由 ActiveRecord encryption 加密
      t.timestamps
    end
  end
end
```

`AddSshCredentialToManagedApps`：

```ruby
class AddSshCredentialToManagedApps < ActiveRecord::Migration[8.1]
  def change
    add_reference :managed_apps, :ssh_credential, foreign_key: { to_table: :credentials }
  end
end
```

```bash
bin/rails db:migrate
```

- [ ] **Step 3: 写失败测试**

`test/models/credential_test.rb`：

```ruby
require "test_helper"

class CredentialTest < ActiveSupport::TestCase
  def key
    File.read(Rails.root.join("test/fake_host/id_ed25519"))
  end

  test "私钥在数据库中是密文" do
    credential = Credential.create!(kind: "ssh_key", value: key)

    raw = Credential.connection.select_value(
      "SELECT value FROM credentials WHERE id = #{credential.id}"
    )

    refute_includes raw.to_s, "PRIVATE KEY"
    assert_equal key, credential.reload.value
  end

  test "指纹可安全展示，且不含私钥内容" do
    credential = Credential.create!(kind: "ssh_key", value: key)

    assert_match(/\ASHA256:/, credential.fingerprint)
    refute_includes credential.fingerprint, "PRIVATE KEY"
  end

  test "拒绝不像私钥的内容" do
    credential = Credential.new(kind: "ssh_key", value: "hello")

    refute credential.valid?
  end
end
```

- [ ] **Step 4: 运行测试，确认失败**

Run: `bin/rails test test/models/credential_test.rb`
Expected: FAIL —— `NameError: uninitialized constant Credential`

- [ ] **Step 5: 实现 Credential**

`app/models/credential.rb`：

```ruby
require "net/ssh"
require "digest"
require "base64"

# 加密存储的 SSH 私钥。
#
# 只写不读（spec 7.2）：UI 永不回显私钥、不提供下载，编辑只能整体替换。
# 因此本模型对外只暴露 fingerprint，value 仅供采集器内部使用。
class Credential < ApplicationRecord
  KINDS = %w[ssh_key].freeze

  encrypts :value

  has_many :managed_apps, foreign_key: :ssh_credential_id, dependent: :nullify,
           inverse_of: :ssh_credential

  validates :kind, inclusion: { in: KINDS }
  validates :value, presence: true
  validate :value_must_be_a_private_key

  def fingerprint
    key = Net::SSH::KeyFactory.load_data_private_key(value, nil, false)
    "SHA256:#{Base64.strict_encode64(Digest::SHA256.digest(key.to_blob)).delete("=")}"
  rescue StandardError
    "（无法读取指纹）"
  end

  private
    def value_must_be_a_private_key
      return if value.blank?

      Net::SSH::KeyFactory.load_data_private_key(value, nil, false)
    rescue StandardError => e
      errors.add(:value, "不是可用的 SSH 私钥：#{e.message}")
    end
end
```

- [ ] **Step 6: 关联到 ManagedApp**

在 `app/models/managed_app.rb` 的校验之前加入：

```ruby
  belongs_to :ssh_credential, class_name: "Credential", optional: true
```

- [ ] **Step 7: 表单接入（只写不读）**

在 `app/views/managed_apps/new.html.erb` 的 `config_yaml` 字段之后加入：

```erb
  <div>
    <%= label_tag :ssh_private_key, "SSH 私钥" %>
    <%= text_area_tag :ssh_private_key, nil, rows: 8 %>
    <small>保存后不再显示，只能整体替换。</small>
  </div>
```

在 `ManagedAppsController#create` 中，`@managed_app = ManagedApp.new(managed_app_params)` 之后加入：

```ruby
    if params[:ssh_private_key].present?
      @managed_app.ssh_credential = Credential.new(kind: "ssh_key", value: params[:ssh_private_key])
    end
```

在 `app/views/managed_apps/show.html.erb` 的 `<dl>` 中加入（**只显示指纹，永不显示私钥**）：

```erb
  <dt>SSH 私钥</dt>
  <dd><%= @managed_app.ssh_credential&.fingerprint || "（未配置）" %></dd>
```

- [ ] **Step 8: 运行测试**

Run: `bin/rails test`
Expected: 全绿

- [ ] **Step 9: 提交**

```bash
git add -A
git commit -m "feat: 加密存储 SSH 私钥，只写不读

私钥用 ActiveRecord encryption 加密，主密钥可从环境变量注入
不落盘。UI 只展示指纹，永不回显私钥、不提供下载。"
```

---

## Task 6: SSH 会话与连通性探测

**Files:**
- Create: `app/services/collectors/ssh_session.rb`
- Create: `app/services/collectors/reachability_probe.rb`
- Create: `test/services/collectors/ssh_session_test.rb`
- Create: `test/services/collectors/reachability_probe_test.rb`

**Interfaces:**
- Consumes: `ManagedApp#parsed_config`、`ManagedApp#ssh_credential`
- Produces:
  - `Collectors::SshSession.new(managed_app)` →
    - `#capture(host, command)` → String（stdout）
    - `#capture_many(hosts) { |host| command }` → `Hash{String => Result}`，`Result` 为 `Struct.new(:host, :stdout, :error)`
  - `Collectors::ReachabilityProbe.call(managed_app)` → `Hash{String => Boolean}`

**关键设计（spec 6.2）：** SSH 连接参数来自用户自己 deploy.yml 里的 `ssh:` 段——user、port、proxy_jump 全部自动继承，不在面板里重配。私钥通过 `key_data` 注入。

- [ ] **Step 1: 写失败测试**

`test/services/collectors/ssh_session_test.rb`：

```ruby
require "test_helper"

class Collectors::SshSessionTest < ExecutionLayerTest
  def managed_app
    @managed_app ||= begin
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
        ssh:
          user: deploy
          port: #{FakeHost::NODES.fetch("node-1")}
      YAML

      ManagedApp.create!(
        name: "blog",
        config_yaml: yaml,
        destination: "production",
        ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key)
      )
    end
  end

  test "用 deploy.yml 里声明的 user 和 port 连上真实主机" do
    session = Collectors::SshSession.new(managed_app)

    assert_equal "deploy", session.capture("127.0.0.1", "whoami").strip
  end

  test "能在目标主机上执行 docker" do
    session = Collectors::SshSession.new(managed_app)

    assert_match(/Server:/, session.capture("127.0.0.1", "docker version"))
  end

  test "capture_many 把每台主机的失败单独装起来，不影响其他主机" do
    session = Collectors::SshSession.new(managed_app)

    results = session.capture_many([ "127.0.0.1" ]) { "echo hello" }

    assert_equal "hello", results["127.0.0.1"].stdout.strip
    assert_nil results["127.0.0.1"].error
  end
end
```

`test/services/collectors/reachability_probe_test.rb`：

```ruby
require "test_helper"

class Collectors::ReachabilityProbeTest < ExecutionLayerTest
  test "逐台报告连通性，不因某台失败而整体失败" do
    yaml = <<~YAML
      service: blog
      image: example/blog
      servers:
        web:
          - 127.0.0.1
          - 192.0.2.1
      registry:
        server: registry.example.com
        username: someone
        password:
          - KAMAL_REGISTRY_PASSWORD
      ssh:
        user: deploy
        port: #{FakeHost::NODES.fetch("node-1")}
    YAML

    app = ManagedApp.create!(
      name: "blog", config_yaml: yaml, destination: "production",
      ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key)
    )

    result = Collectors::ReachabilityProbe.call(app)

    assert_equal true,  result["127.0.0.1"]
    assert_equal false, result["192.0.2.1"]   # TEST-NET-1，保证连不通
  end
end
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bin/rails test test/services/collectors/`
Expected: FAIL —— `NameError: uninitialized constant Collectors::SshSession`

- [ ] **Step 3: 实现 SshSession**

`app/services/collectors/ssh_session.rb`：

```ruby
require "net/ssh"

# 对被管应用的 SSH 访问。
#
# 连接参数直接取自用户 deploy.yml 的 ssh: 段（spec 6.2）：
# user、port、proxy 全部自动继承，不在面板里重复配置。
# 这样不会出现「kamal 能连、面板连不上」的情况。
module Collectors
  class SshSession
    Result = Struct.new(:host, :stdout, :error, keyword_init: true)

    CONNECT_TIMEOUT = 10

    def initialize(managed_app)
      @managed_app = managed_app
    end

    def capture(host, command)
      Net::SSH.start(host, ssh_user, **net_ssh_options) do |session|
        session.exec!(command).to_s
      end
    end

    # 对多台主机执行命令。单台失败被装进该主机自己的 Result，
    # 不会中断其他主机（spec 6.4：失联要显式呈现，不能让整轮采集失败）。
    def capture_many(hosts)
      hosts.each_with_object({}) do |host, results|
        results[host] =
          begin
            Result.new(host: host, stdout: capture(host, yield(host)), error: nil)
          rescue StandardError => e
            Result.new(host: host, stdout: nil, error: "#{e.class}: #{e.message}")
          end
      end
    end

    private
      attr_reader :managed_app

      def ssh_options
        managed_app.parsed_config.ssh_options
      end

      def ssh_user
        ssh_options[:user] || "root"
      end

      def net_ssh_options
        {
          port: ssh_options[:port] || 22,
          key_data: [ managed_app.ssh_credential&.value ].compact,
          keys_only: true,
          auth_methods: [ "publickey" ],
          verify_host_key: :never,
          timeout: CONNECT_TIMEOUT,
          non_interactive: true
        }
      end
  end
end
```

> `verify_host_key: :never` 是 v1 的显式取舍：面板没有 known_hosts 管理界面。这条要写进 README 的安全说明，并在计划 03 中评估补上 host key 固定。

- [ ] **Step 4: 实现 ReachabilityProbe**

`app/services/collectors/reachability_probe.rb`：

```ruby
module Collectors
  # 接入时的连通性探测：逐台列出成功/失败（spec 5.3 第 2 步）。
  class ReachabilityProbe
    def self.call(managed_app)
      session = SshSession.new(managed_app)

      session
        .capture_many(managed_app.app_hosts) { "echo ok" }
        .transform_values { |result| result.error.nil? && result.stdout.to_s.strip == "ok" }
    end
  end
end
```

- [ ] **Step 5: 运行测试，确认通过**

Run: `bin/rails test test/services/collectors/`
Expected: 4 runs, 0 failures

若 `192.0.2.1` 那条耗时过长，确认 `timeout: CONNECT_TIMEOUT` 生效。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat: SSH 会话与连通性探测

连接参数取自用户 deploy.yml 的 ssh: 段，跳板机/非标端口/专用
用户全部自动继承。单台主机失败被装进自己的 Result，不中断整轮采集。"
```

---

## Task 7: 容器采集器

**Files:**
- Create: `db/migrate/<ts>_create_observations.rb`
- Create: `app/models/observation.rb`
- Create: `app/services/collectors/container_collector.rb`
- Create: `test/models/observation_test.rb`
- Create: `test/services/collectors/container_collector_test.rb`

**Interfaces:**
- Consumes: `Collectors::SshSession`（Task 6）
- Produces:
  - `Collectors::ContainerCollector.call(managed_app)` → Integer（本轮写入的 Observation 行数）
  - `Observation` 字段：`managed_app_id, host, role, container_name, version, docker_status, health, reachable, error, observed_at`
  - `Observation.latest_for(managed_app)` → `ActiveRecord::Relation`（每个 host 最近一轮）

- [ ] **Step 1: 建表**

```bash
bin/rails generate migration CreateObservations
```

```ruby
class CreateObservations < ActiveRecord::Migration[8.1]
  def change
    create_table :observations do |t|
      t.references :managed_app, null: false, foreign_key: true
      t.string   :host, null: false
      t.string   :role
      t.string   :container_name
      t.string   :version
      t.string   :docker_status
      t.string   :health
      t.boolean  :reachable, null: false, default: true
      t.string   :error
      t.datetime :observed_at, null: false
      t.datetime :created_at, null: false
    end

    add_index :observations, [ :managed_app_id, :observed_at ]
    add_index :observations, [ :managed_app_id, :host, :observed_at ]
  end
end
```

```bash
bin/rails db:migrate
```

- [ ] **Step 2: 写失败测试**

`test/models/observation_test.rb`：

```ruby
require "test_helper"

class ObservationTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(
      name: "blog",
      config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )
  end

  test "Observation 不可更新" do
    observation = Observation.create!(
      managed_app: @app, host: "10.0.0.1", docker_status: "running",
      observed_at: Time.current
    )

    assert_raises(ActiveRecord::ReadOnlyRecord) do
      observation.update!(docker_status: "exited")
    end
  end

  test "latest_for 只返回每台主机最近一轮" do
    old_time = 10.minutes.ago
    new_time = Time.current

    Observation.create!(managed_app: @app, host: "10.0.0.1", version: "old",
                        docker_status: "running", observed_at: old_time)
    Observation.create!(managed_app: @app, host: "10.0.0.1", version: "new",
                        docker_status: "running", observed_at: new_time)
    Observation.create!(managed_app: @app, host: "10.0.0.2", version: "other",
                        docker_status: "running", observed_at: new_time)

    versions = Observation.latest_for(@app).pluck(:version).sort

    assert_equal %w[new other], versions
  end
end
```

`test/services/collectors/container_collector_test.rb`：

```ruby
require "test_helper"

class Collectors::ContainerCollectorTest < ExecutionLayerTest
  def build_app(hosts:)
    yaml = <<~YAML
      service: blog
      image: example/blog
      servers:
        web:
      #{hosts.map { |h| "      - #{h}" }.join("\n")}
      registry:
        server: registry.example.com
        username: someone
        password:
          - KAMAL_REGISTRY_PASSWORD
      ssh:
        user: deploy
        port: #{FakeHost::NODES.fetch("node-1")}
    YAML

    ManagedApp.create!(
      name: "blog-#{SecureRandom.hex(4)}", config_yaml: yaml, destination: "production",
      ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key)
    )
  end

  test "采集到运行中的容器，并解析出版本与角色" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")

    app = build_app(hosts: [ "127.0.0.1" ])
    Collectors::ContainerCollector.call(app)

    observation = Observation.latest_for(app).first

    assert_equal "aaaaaaa", observation.version
    assert_equal "web", observation.role
    assert_equal "blog-web-production-aaaaaaa", observation.container_name
    assert_equal "running", observation.docker_status
    assert observation.reachable
  end

  test "已停止的旧版本容器也被采集到——这就是回滚候选" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "0000000",
                            state: :stopped)

    app = build_app(hosts: [ "127.0.0.1" ])
    Collectors::ContainerCollector.call(app)

    by_version = Observation.latest_for(app).index_by(&:version)

    assert_equal "running", by_version["aaaaaaa"].docker_status
    assert_equal "exited",  by_version["0000000"].docker_status
  end

  test "只采集本应用的容器，不串到别的 service" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")
    FakeHost.seed_container(node: "node-1", service: "shop", role: "web",
                            destination: "production", version: "bbbbbbb")

    app = build_app(hosts: [ "127.0.0.1" ])
    Collectors::ContainerCollector.call(app)

    versions = Observation.latest_for(app).pluck(:version)

    assert_equal [ "aaaaaaa" ], versions
  end

  test "主机连不上时写一条 unreachable 记录，而不是什么都不写" do
    app = build_app(hosts: [ "192.0.2.1" ])
    Collectors::ContainerCollector.call(app)

    observation = Observation.latest_for(app).first

    refute observation.reachable
    assert_predicate observation.error, :present?
  end
end
```

- [ ] **Step 3: 运行测试，确认失败**

Run: `bin/rails test test/models/observation_test.rb test/services/collectors/container_collector_test.rb`
Expected: FAIL —— `NameError: uninitialized constant Observation`

- [ ] **Step 4: 实现 Observation**

`app/models/observation.rb`：

```ruby
# 一条不可变的观测快照（spec 5.2）。
#
# 只追加，绝不 UPDATE。这样「14:32 running → 14:35 unhealthy」
# 天然可查，且 UI 能诚实显示数据年龄。
class Observation < ApplicationRecord
  belongs_to :managed_app

  validates :host, presence: true
  validates :observed_at, presence: true

  # 已持久化的记录一律只读——从模型层堵死误改
  def readonly?
    persisted?
  end

  # 每台主机最近一轮的全部记录
  def self.latest_for(managed_app)
    latest_times = where(managed_app: managed_app)
                     .group(:host)
                     .maximum(:observed_at)

    return none if latest_times.empty?

    conditions = latest_times.map { |host, time| sanitize_sql([ "(host = ? AND observed_at = ?)", host, time ]) }

    where(managed_app: managed_app).where(conditions.join(" OR "))
  end

  def self.last_observed_at_for(managed_app)
    where(managed_app: managed_app).maximum(:observed_at)
  end
end
```

- [ ] **Step 5: 实现 ContainerCollector**

`app/services/collectors/container_collector.rb`：

```ruby
require "json"

module Collectors
  # 每个 ManagedApp × 每台 host 一条命令，取回该应用的全部容器。
  #
  #   docker ps --all --filter label=service=X --filter label=destination=Y --format '{{json .}}'
  #
  # --all 是关键：已停止的旧版本容器一并返回，这就是回滚候选列表，
  # 面板无需自建版本历史（spec 6.1）。
  class ContainerCollector
    def self.call(managed_app)
      new(managed_app).call
    end

    def initialize(managed_app)
      @managed_app = managed_app
      @observed_at = Time.current
    end

    def call
      rows = []

      results.each do |host, result|
        rows.concat(
          if result.error
            [ unreachable_row(host, result.error) ]
          else
            container_rows(host, result.stdout)
          end
        )
      end

      Observation.insert_all!(rows) if rows.any?
      rows.size
    end

    private
      attr_reader :managed_app, :observed_at

      def results
        SshSession.new(managed_app).capture_many(managed_app.app_hosts) { docker_ps_command }
      end

      # 注意两处，都是实施 Task 7 时踩出来的：
      #
      # 1. service / destination 来自用户粘贴的 deploy.yml，且字符集不受约束。
      #    它们进入远端 shell 命令串，必须 Shellwords.escape。
      #    （Task 6 为「未校验的配置值抵达 shell」这一类 bug 花了 5 轮修复。）
      #
      # 2. 不要用 --format '{{json .}}' 然后去解析它的 Labels 字段：
      #    Docker 把所有 label 压成一个逗号连接的 k=v 字符串，
      #    service 或 destination 里只要有一个逗号，role 与 version 就会被静默解析错——
      #    面板会显示错误的角色和版本，而运维正是在事故中盯着它。
      #    改为让 Docker 逐字段 JSON 编码地吐出我们需要的字段。
      def docker_ps_command
        filters = [ "label=service=#{Shellwords.escape(managed_app.service)}" ]
        if managed_app.destination.present?
          filters << "label=destination=#{Shellwords.escape(managed_app.destination)}"
        end

        format = %({"name":{{json .Names}},"state":{{json .State}},) +
                 %("status":{{json .Status}},"role":{{json (.Label "role")}}})

        [
          "docker ps --all",
          *filters.map { |f| "--filter #{f}" },
          "--format #{Shellwords.escape(format)}"
        ].join(" ")
      end

      def container_rows(host, stdout)
        lines = stdout.to_s.lines.map(&:strip).reject(&:blank?)

        # 没有任何容器也要留痕：这台机器是可达的，只是没东西在跑
        return [ empty_row(host) ] if lines.empty?

        lines.filter_map { |line| container_row(host, line) }
      end

      def container_row(host, line)
        data = JSON.parse(line)
        labels = parse_labels(data["Labels"])
        name = data["Names"].to_s

        base_row(host).merge(
          role: labels["role"],
          container_name: name,
          version: extract_version(name, labels),
          docker_status: data["State"],
          health: extract_health(data["Status"])
        )
      rescue JSON::ParserError
        nil
      end

      # 容器名格式 service-role-destination-VERSION
      # （Kamal::Configuration::Role#container_name）
      def extract_version(name, labels)
        prefix = [ managed_app.service, labels["role"], labels["destination"] ].compact.join("-")
        return nil unless name.start_with?("#{prefix}-")

        name.delete_prefix("#{prefix}-")
      end

      # docker ps 的 Status 形如 "Up 3 minutes (healthy)"
      def extract_health(status)
        status.to_s[/\((healthy|unhealthy|health: starting)\)/, 1]
      end

      def parse_labels(labels)
        labels.to_s.split(",").to_h { |pair| pair.split("=", 2) }
      rescue StandardError
        {}
      end

      def base_row(host)
        { managed_app_id: managed_app.id, host: host, reachable: true,
          observed_at: observed_at, created_at: observed_at }
      end

      def empty_row(host)
        base_row(host)
      end

      def unreachable_row(host, error)
        base_row(host).merge(reachable: false, error: error.truncate(255))
      end
  end
end
```

- [ ] **Step 6: 运行测试，确认通过**

Run: `bin/rails test test/models/observation_test.rb test/services/collectors/container_collector_test.rb`
Expected: 6 runs, 0 failures

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "feat: 容器采集器，Observation 只追加

一条 docker ps --all 取回某应用在某台机器上的全部容器（含已停止的
旧版本＝回滚候选）。主机连不上时写 unreachable 记录而不是什么都不
写——UI 才能区分「服务挂了」和「面板瞎了」。

Observation#readonly? 从模型层堵死更新。"
```

---

## Task 8: kamal-proxy 路由采集器

**Files:**
- Create: `db/migrate/<ts>_create_proxy_targets.rb`
- Create: `app/models/proxy_target.rb`
- Create: `app/services/collectors/proxy_collector.rb`
- Modify: `test/support/fake_host_helper.rb`
- Create: `test/services/collectors/proxy_collector_test.rb`

**Interfaces:**
- Consumes: `Collectors::SshSession`（Task 6）
- Produces:
  - `Collectors::ProxyCollector.call(managed_app)` → Integer（写入行数）
  - `ProxyTarget` 字段：`managed_app_id, host, service_name, target, state, raw, observed_at`
  - `FakeHost.start_proxy(node)` → void
  - `FakeHost.proxy_deploy(node:, service:, target:)` → void

**为什么需要（spec 6.1）：** 容器在运行 ≠ 在接流量。只有 kamal-proxy 的路由表能回答「用户访问域名时流量实际到达哪个容器」。

- [ ] **Step 1: 给 fake host 加 kamal-proxy 支持**

在 `test/support/fake_host_helper.rb` 中加入：

```ruby
  PROXY_IMAGE = "basecamp/kamal-proxy:v0.10.0".freeze

  def self.start_proxy(node)
    ssh node, <<~SH
      docker run -d --name kamal-proxy \
        --restart unless-stopped \
        --publish 8080:80 \
        #{PROXY_IMAGE}
    SH

    # 等 proxy 的 RPC socket 就绪
    20.times do
      return if ssh(node, "docker exec kamal-proxy kamal-proxy list --json 2>/dev/null").present?
      sleep 0.5
    end

    raise NotReady, "kamal-proxy 在 #{node} 上未能就绪"
  end

  def self.proxy_deploy(node:, service:, target:)
    ssh node, "docker exec kamal-proxy kamal-proxy deploy #{service} --target #{target}"
  end
```

并在 entrypoint 的预拉镜像一行旁边补上（`test/fake_host/entrypoint.sh`）：

```sh
docker pull basecamp/kamal-proxy:v0.10.0 >/dev/null 2>&1 || true
```

改完后重建镜像：

```bash
docker compose -f docker-compose.test.yml up -d --build
```

- [ ] **Step 2: 建表**

```bash
bin/rails generate migration CreateProxyTargets
```

```ruby
class CreateProxyTargets < ActiveRecord::Migration[8.1]
  def change
    create_table :proxy_targets do |t|
      t.references :managed_app, null: false, foreign_key: true
      t.string   :host, null: false
      t.string   :service_name
      t.string   :target
      t.string   :state
      t.text     :raw
      t.datetime :observed_at, null: false
      t.datetime :created_at, null: false
    end

    add_index :proxy_targets, [ :managed_app_id, :observed_at ]
  end
end
```

```bash
bin/rails db:migrate
```

- [ ] **Step 3: 写失败测试**

`test/services/collectors/proxy_collector_test.rb`：

```ruby
require "test_helper"

class Collectors::ProxyCollectorTest < ExecutionLayerTest
  setup do
    FakeHost.start_proxy("node-1")
  end

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
      ssh:
        user: deploy
        port: #{FakeHost::NODES.fetch("node-1")}
    YAML

    ManagedApp.create!(
      name: "blog-#{SecureRandom.hex(4)}", config_yaml: yaml, destination: "production",
      ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key)
    )
  end

  test "proxy 上没有任何路由时，采集成功且结果为空" do
    app = build_app

    assert_equal 0, Collectors::ProxyCollector.call(app)
    assert_empty ProxyTarget.where(managed_app: app)
  end

  test "采集到已部署的路由目标" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")
    FakeHost.proxy_deploy(node: "node-1", service: "blog-web-production",
                          target: "blog-web-production-aaaaaaa:80")

    app = build_app
    Collectors::ProxyCollector.call(app)

    target = ProxyTarget.where(managed_app: app).order(:id).last

    assert_equal "blog-web-production", target.service_name
    assert_match(/blog-web-production-aaaaaaa/, target.target)
  end

  test "机器上没跑 kamal-proxy 时不报错，只是没有路由数据" do
    FakeHost.ssh("node-1", "docker rm -f kamal-proxy")

    app = build_app

    assert_nothing_raised { Collectors::ProxyCollector.call(app) }
    assert_empty ProxyTarget.where(managed_app: app)
  end
end
```

- [ ] **Step 4: 运行测试，确认失败**

Run: `bin/rails test test/services/collectors/proxy_collector_test.rb`
Expected: FAIL —— `NameError: uninitialized constant Collectors::ProxyCollector`

- [ ] **Step 5: 实现 ProxyTarget**

`app/models/proxy_target.rb`：

```ruby
# kamal-proxy 路由表的快照。与 Observation 一样只追加。
class ProxyTarget < ApplicationRecord
  belongs_to :managed_app

  def readonly?
    persisted?
  end

  def self.latest_for(managed_app)
    latest = where(managed_app: managed_app).maximum(:observed_at)
    return none if latest.nil?

    where(managed_app: managed_app, observed_at: latest)
  end
end
```

- [ ] **Step 6: 实现 ProxyCollector**

`app/services/collectors/proxy_collector.rb`：

```ruby
require "json"

module Collectors
  # 取回每台机器上 kamal-proxy 的路由表。
  #
  #   docker exec kamal-proxy kamal-proxy list --json
  #
  # 这是唯一能回答「流量实际到达哪个容器」的数据源——docker ps 看不出
  # 一个正在运行的容器是否在接流量（spec 6.1）。
  #
  # 机器上没跑 kamal-proxy 是完全正常的情况（用户可能用别的入口），
  # 因此命令失败不视为错误，只是没有路由数据。
  class ProxyCollector
    COMMAND = "docker exec kamal-proxy kamal-proxy list --json 2>/dev/null".freeze

    def self.call(managed_app)
      new(managed_app).call
    end

    def initialize(managed_app)
      @managed_app = managed_app
      @observed_at = Time.current
    end

    def call
      rows = results.flat_map { |host, result| rows_for(host, result) }

      ProxyTarget.insert_all!(rows) if rows.any?
      rows.size
    end

    private
      attr_reader :managed_app, :observed_at

      def results
        SshSession.new(managed_app).capture_many(managed_app.app_hosts) { COMMAND }
      end

      def rows_for(host, result)
        return [] if result.error || result.stdout.blank?

        parse_targets(result.stdout)
          .select { |entry| belongs_to_this_app?(entry) }
          .map { |entry| row(host, entry) }
      end

      # kamal-proxy list --json 输出 ListResponse 的 Targets。
      # 其具体形状随 kamal-proxy 版本变化，因此原文一并存进 raw 列，
      # 便于排查与后续适配。
      def parse_targets(stdout)
        parsed = JSON.parse(stdout)

        case parsed
        when Array then parsed
        when Hash  then parsed.values.flatten.select { |v| v.is_a?(Hash) }
        else []
        end
      rescue JSON::ParserError
        []
      end

      def belongs_to_this_app?(entry)
        name = service_name_of(entry).to_s
        prefixes = managed_app.parsed_config.roles.map { |role| role[:container_prefix] }

        prefixes.any? { |prefix| name == prefix }
      end

      def service_name_of(entry)
        entry["service"] || entry["Service"] || entry["name"] || entry["Name"]
      end

      def target_of(entry)
        entry["target"] || entry["Target"] || entry["hosts"] || entry["Hosts"]
      end

      def state_of(entry)
        entry["state"] || entry["State"]
      end

      def row(host, entry)
        {
          managed_app_id: managed_app.id,
          host: host,
          service_name: service_name_of(entry),
          target: Array(target_of(entry)).join(", ").presence,
          state: state_of(entry),
          raw: JSON.generate(entry),
          observed_at: observed_at,
          created_at: observed_at
        }
      end
  end
end
```

- [ ] **Step 7: 运行测试，确认通过**

Run: `bin/rails test test/services/collectors/proxy_collector_test.rb`
Expected: 3 runs, 0 failures

若第二个测试失败，先手工执行看真实输出形状，据此调整 `parse_targets`：

```bash
ssh -i test/fake_host/id_ed25519 -o StrictHostKeyChecking=no \
    -p 2201 deploy@127.0.0.1 'docker exec kamal-proxy kamal-proxy list --json'
```

- [ ] **Step 8: 提交**

```bash
git add -A
git commit -m "feat: kamal-proxy 路由采集器

容器在运行 ≠ 在接流量。只有 kamal-proxy 的路由表能回答流量实际
到达哪个容器，这在 UI 上要与容器状态分开显示。

机器上没跑 kamal-proxy 视为正常情况，不报错。输出原文存进 raw
列，便于后续适配 kamal-proxy 的版本差异。"
```

---

## Task 9: 轮询编排

**Files:**
- Create: `app/jobs/poll_managed_app_job.rb`
- Create: `app/services/poll_cadence.rb`
- Modify: `config/recurring.yml`
- Create: `app/jobs/poll_all_managed_apps_job.rb`
- Create: `test/jobs/poll_managed_app_job_test.rb`
- Create: `test/services/poll_cadence_test.rb`

**Interfaces:**
- Consumes: `Collectors::ContainerCollector`、`Collectors::ProxyCollector`
- Produces:
  - `PollManagedAppJob.perform_later(managed_app)`
  - `PollCadence.interval_for(managed_app, now: Time.current)` → ActiveSupport::Duration
  - `PollCadence.mark_viewed!(managed_app)` → void
  - `PollCadence.mark_burst!(managed_app)` → void

**节奏（spec 6.3）：** 无人看 60s ／ 有人正在看 10s ／ 刚有动静 2s 持续 90s。

- [ ] **Step 1: 写失败测试**

`test/services/poll_cadence_test.rb`：

```ruby
require "test_helper"

class PollCadenceTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(
      name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )
    Rails.cache.clear
  end

  test "默认无人查看时 60 秒" do
    assert_equal 60.seconds, PollCadence.interval_for(@app)
  end

  test "有人正在查看时 10 秒" do
    PollCadence.mark_viewed!(@app)

    assert_equal 10.seconds, PollCadence.interval_for(@app)
  end

  test "burst 期间 2 秒" do
    PollCadence.mark_burst!(@app)

    assert_equal 2.seconds, PollCadence.interval_for(@app)
  end

  test "burst 90 秒后回落" do
    PollCadence.mark_burst!(@app)

    travel 91.seconds do
      assert_equal 60.seconds, PollCadence.interval_for(@app)
    end
  end

  test "burst 优先于 viewing" do
    PollCadence.mark_viewed!(@app)
    PollCadence.mark_burst!(@app)

    assert_equal 2.seconds, PollCadence.interval_for(@app)
  end
end
```

`test/jobs/poll_managed_app_job_test.rb`：

```ruby
require "test_helper"

class PollManagedAppJobTest < ExecutionLayerTest
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
      ssh:
        user: deploy
        port: #{FakeHost::NODES.fetch("node-1")}
    YAML

    ManagedApp.create!(
      name: "blog-#{SecureRandom.hex(4)}", config_yaml: yaml, destination: "production",
      ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key)
    )
  end

  test "一次轮询同时写入容器观测与路由快照" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")

    app = build_app
    PollManagedAppJob.perform_now(app)

    assert_equal "aaaaaaa", Observation.latest_for(app).first.version
  end

  test "采集器抛异常时任务不崩溃，并留下 unreachable 痕迹" do
    app = build_app
    app.update_column(:config_yaml, app.config_yaml.sub("127.0.0.1", "192.0.2.1"))
    app.reload

    assert_nothing_raised { PollManagedAppJob.perform_now(app) }
    refute Observation.latest_for(app).first.reachable
  end
end
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bin/rails test test/services/poll_cadence_test.rb test/jobs/poll_managed_app_job_test.rb`
Expected: FAIL —— `NameError: uninitialized constant PollCadence`

- [ ] **Step 3: 实现 PollCadence**

`app/services/poll_cadence.rb`：

```ruby
# 自适应轮询节奏（spec 6.3）。
#
# 没人看的时候不该烧 SSH 连接；有人正在看、或刚有动静时才加密。
class PollCadence
  IDLE     = 60.seconds
  VIEWING  = 10.seconds
  BURST    = 2.seconds

  VIEWING_TTL = 30.seconds   # 页面每 10 秒续一次，30 秒不续即视为无人查看
  BURST_TTL   = 90.seconds

  class << self
    def interval_for(managed_app, now: Time.current)
      return BURST   if flag?(managed_app, :burst)
      return VIEWING if flag?(managed_app, :viewing)

      IDLE
    end

    def mark_viewed!(managed_app)
      Rails.cache.write(key(managed_app, :viewing), true, expires_in: VIEWING_TTL)
    end

    def mark_burst!(managed_app)
      Rails.cache.write(key(managed_app, :burst), true, expires_in: BURST_TTL)
    end

    private
      def flag?(managed_app, name)
        Rails.cache.read(key(managed_app, name)).present?
      end

      def key(managed_app, name)
        "poll_cadence/#{managed_app.id}/#{name}"
      end
  end
end
```

> `travel` 需要缓存的过期判断随时间变化。Rails 的 `:memory_store` 使用 `Time.now`，与 `travel` 兼容。若测试环境默认是 `:null_store`，在 `config/environments/test.rb` 中改为 `config.cache_store = :memory_store`。

- [ ] **Step 4: 实现轮询任务**

`app/jobs/poll_managed_app_job.rb`：

```ruby
# 一个应用的一轮采集。
#
# 单个采集器失败不得让整轮失败——失联本身就是要采集并呈现的信息
# （spec 6.4）。
class PollManagedAppJob < ApplicationJob
  queue_as :default

  def perform(managed_app)
    Collectors::ContainerCollector.call(managed_app)
    Collectors::ProxyCollector.call(managed_app)
  rescue Kamal::ConfigParser::ParseError => e
    # deploy.yml 现在解析不了了（用户改坏了配置）。记录并跳过这一轮。
    Rails.logger.warn("[poll] #{managed_app.name} 的 deploy.yml 无法解析：#{e.message}")
  end
end
```

`app/jobs/poll_all_managed_apps_job.rb`：

```ruby
# 由 Solid Queue 的 recurring 定时触发。
# 每个应用按自己的节奏决定这一轮是否该跑（spec 6.3）。
class PollAllManagedAppsJob < ApplicationJob
  queue_as :default

  def perform
    ManagedApp.find_each do |managed_app|
      next unless due?(managed_app)

      PollManagedAppJob.perform_later(managed_app)
      Rails.cache.write(last_run_key(managed_app), Time.current, expires_in: 1.hour)
    end
  end

  private
    def due?(managed_app)
      last_run = Rails.cache.read(last_run_key(managed_app))
      return true if last_run.blank?

      Time.current - last_run >= PollCadence.interval_for(managed_app)
    end

    def last_run_key(managed_app)
      "poll_cadence/#{managed_app.id}/last_run"
    end
end
```

`config/recurring.yml` 加入：

```yaml
production: &default
  poll_all_managed_apps:
    class: PollAllManagedAppsJob
    schedule: every second

development:
  <<: *default
```

> 每秒触发的只是这个调度器本身，它非常轻（只读缓存判断是否到点）。实际的 SSH 采集由 `PollCadence` 控制频率。

- [ ] **Step 5: 运行测试，确认通过**

Run: `bin/rails test test/services/poll_cadence_test.rb test/jobs/poll_managed_app_job_test.rb`
Expected: 7 runs, 0 failures

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat: 自适应轮询编排

无人查看 60s、有人在看 10s、刚有动静 2s 持续 90s。调度器每秒
触发但极轻，实际 SSH 采集频率由 PollCadence 控制。

采集器异常不让整轮失败——失联本身就是要呈现的信息。"
```

---

## Task 10: 应用状态计算与总览页

**Files:**
- Create: `app/services/managed_app_status.rb`
- Create: `app/controllers/overviews_controller.rb`
- Create: `app/views/overviews/show.html.erb`
- Create: `app/views/overviews/_grid.html.erb`
- Modify: `config/routes.rb`
- Create: `test/services/managed_app_status_test.rb`
- Create: `test/system/overview_test.rb`

**Interfaces:**
- Consumes: `Observation.latest_for`、`ProxyTarget.latest_for`
- Produces:
  - `ManagedAppStatus.new(managed_app)` →
    - `#level` → `:drift` / `:unhealthy` / `:unreachable` / `:ok` / `:unknown`
    - `#label` → String（中文文字标识，**状态不能只靠颜色**）
    - `#versions` → Array<String>
    - `#drift?` → Boolean
    - `#observed_at` → Time / nil
    - `#host_rows` → Array<Hash>，每项 `{ host:, role:, version:, docker_status:, health:, reachable:, routed: }`

**版本漂移是一等公民（spec 8.1）：** 它排在所有状态之前，因为它意味着「部署没做完」。

- [ ] **Step 1: 写失败测试**

`test/services/managed_app_status_test.rb`：

```ruby
require "test_helper"

class ManagedAppStatusTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(
      name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )
    @now = Time.current
  end

  def observe(host:, version: nil, docker_status: "running", health: nil, reachable: true)
    Observation.create!(
      managed_app: @app, host: host, role: "web",
      container_name: version && "blog-web-production-#{version}",
      version: version, docker_status: docker_status, health: health,
      reachable: reachable, observed_at: @now
    )
  end

  test "所有机器版本一致且运行中 → ok" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", version: "aaaaaaa")

    status = ManagedAppStatus.new(@app)

    assert_equal :ok, status.level
    refute status.drift?
  end

  test "不同机器版本不一致 → drift，且优先级最高" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", version: "bbbbbbb")

    status = ManagedAppStatus.new(@app)

    assert_equal :drift, status.level
    assert status.drift?
    assert_equal %w[aaaaaaa bbbbbbb], status.versions.sort
  end

  test "版本漂移优先于容器异常" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", version: "bbbbbbb", docker_status: "exited")

    assert_equal :drift, ManagedAppStatus.new(@app).level
  end

  test "已停止的旧版本不算进漂移判断" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.1", version: "0000000", docker_status: "exited")
    observe(host: "10.0.0.2", version: "aaaaaaa")

    assert_equal :ok, ManagedAppStatus.new(@app).level
  end

  test "容器 unhealthy → unhealthy" do
    observe(host: "10.0.0.1", version: "aaaaaaa", health: "unhealthy")

    assert_equal :unhealthy, ManagedAppStatus.new(@app).level
  end

  test "有机器失联 → unreachable" do
    observe(host: "10.0.0.1", version: "aaaaaaa")
    observe(host: "10.0.0.2", reachable: false)

    assert_equal :unreachable, ManagedAppStatus.new(@app).level
  end

  test "从未采集过 → unknown" do
    assert_equal :unknown, ManagedAppStatus.new(@app).level
  end

  test "每个状态都有文字标识，不只靠颜色" do
    observe(host: "10.0.0.1", version: "aaaaaaa")

    assert_predicate ManagedAppStatus.new(@app).label, :present?
  end
end
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bin/rails test test/services/managed_app_status_test.rb`
Expected: FAIL —— `NameError: uninitialized constant ManagedAppStatus`

- [ ] **Step 3: 实现状态计算**

`app/services/managed_app_status.rb`：

```ruby
# 由最近一轮 Observation 计算应用状态。
#
# 优先级（spec 8.2）：
#   drift > unhealthy > unreachable > ok
#
# 版本漂移排最前，因为它意味着「部署没做完」——比单个容器异常更需要
# 立刻处理，且在 CLI 下极难发现。
class ManagedAppStatus
  LEVELS = {
    drift:       "版本不一致",
    unhealthy:   "容器异常",
    unreachable: "机器失联",
    ok:          "正常",
    unknown:     "尚未采集"
  }.freeze

  RUNNING_STATUSES = %w[running restarting].freeze

  def initialize(managed_app)
    @managed_app = managed_app
  end

  def level
    return :unknown     if observations.empty?
    return :drift       if drift?
    return :unhealthy   if unhealthy?
    return :unreachable if unreachable?

    :ok
  end

  def label
    LEVELS.fetch(level)
  end

  def drift?
    versions.size > 1
  end

  # 漂移判断要【按主机】决定「这台机器在哪个版本上」，不能全局过滤运行中容器。
  #
  # 每台机器：有运行中的容器就取它的版本；一个都没有，就回落到该机器上
  # 那个已停止容器的版本——因为「这台卡在旧版本、而且容器已经死了」
  # 恰恰是一次没做完的部署，正是漂移要表达的东西。
  #
  # 若改为全局 running_observations.filter_map(&:version)，
  # 一台只有 exited 容器的机器会贡献为空，漂移被掩盖——
  # 本任务测试「版本漂移优先于容器异常」就会失败。（实施 Task 10 时发现。）
  #
  # 同时仍要满足「已停止的旧版本不算进漂移判断」：同一台机器上
  # 既有运行中又有已停止的容器时，只取运行中的那个版本。
  def versions
    observations.group_by(&:host).filter_map { |_host, rows|
      running = rows.select { |o| RUNNING_STATUSES.include?(o.docker_status) }
      (running.presence || rows).filter_map(&:version).first
    }.uniq
  end

  def observed_at
    Observation.last_observed_at_for(managed_app)
  end

  def host_rows
    observations.map do |observation|
      {
        host: observation.host,
        role: observation.role,
        version: observation.version,
        docker_status: observation.docker_status,
        health: observation.health,
        reachable: observation.reachable,
        error: observation.error,
        routed: routed_targets.include?(observation.container_name)
      }
    end
  end

  private
    attr_reader :managed_app

    def observations
      @observations ||= Observation.latest_for(managed_app).to_a
    end

    def running_observations
      observations.select { |o| RUNNING_STATUSES.include?(o.docker_status) }
    end

    def unhealthy?
      observations.any? { |o| o.health == "unhealthy" } ||
        running_observations.empty? && observations.any? { |o| o.reachable && o.container_name.present? }
    end

    def unreachable?
      observations.any? { |o| !o.reachable }
    end

    def routed_targets
      @routed_targets ||= ProxyTarget.latest_for(managed_app).flat_map { |t| t.target.to_s.split(", ") }
                                     .map { |t| t.split(":").first }
    end
end
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `bin/rails test test/services/managed_app_status_test.rb`
Expected: 8 runs, 0 failures

- [ ] **Step 5: 总览控制器与路由**

`config/routes.rb` 中把 root 改为总览：

```ruby
  resource :overview, only: [ :show ]
  root "overviews#show"
```

`app/controllers/overviews_controller.rb`：

```ruby
class OverviewsController < ApplicationController
  def show
    @managed_apps = ManagedApp.order(:name).to_a
    @statuses = @managed_apps.index_with { |app| ManagedAppStatus.new(app) }

    # 页面正在被查看 → 提高该应用的采集频率（spec 6.3）
    @managed_apps.each { |app| PollCadence.mark_viewed!(app) }
  end
end
```

- [ ] **Step 6: 总览视图**

`app/views/overviews/show.html.erb`：

```erb
<h1>总览</h1>

<% if @managed_apps.empty? %>
  <p>还没有接入任何应用。<%= link_to "接入一个", new_managed_app_path %></p>
<% else %>
  <%= render "grid", managed_apps: @managed_apps, statuses: @statuses %>
<% end %>
```

`app/views/overviews/_grid.html.erb`：

```erb
<table class="overview-grid">
  <thead>
    <tr>
      <th>应用</th>
      <th>状态</th>
      <th>运行中的版本</th>
      <th>机器</th>
      <th>数据年龄</th>
    </tr>
  </thead>
  <tbody>
    <% managed_apps.each do |app| %>
      <% status = statuses[app] %>
      <tr class="status-<%= status.level %>">
        <td><%= link_to app.name, app %></td>
        <td>
          <%# 状态绝不只靠颜色：这里同时给出文字（spec 8.6） %>
          <span class="status-badge status-<%= status.level %>">
            <%= status.label %>
          </span>
        </td>
        <td>
          <% if status.versions.empty? %>
            —
          <% else %>
            <%= status.versions.join(" / ") %>
            <% if status.drift? %>
              <strong>（<%= status.versions.size %> 个版本并存）</strong>
            <% end %>
          <% end %>
        </td>
        <td><%= app.app_hosts.size %></td>
        <td>
          <% if status.observed_at %>
            <%= time_ago_in_words(status.observed_at) %>前
          <% else %>
            从未采集
          <% end %>
        </td>
      </tr>
    <% end %>
  </tbody>
</table>
```

- [ ] **Step 7: 写系统测试**

`test/system/overview_test.rb`：

```ruby
require "application_system_test_case"

class OverviewTest < ApplicationSystemTestCase
  setup do
    @app = ManagedApp.create!(
      name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )
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

    visit root_path

    assert_text "前"
  end
end
```

- [ ] **Step 8: 运行全部测试**

Run: `bin/rails test:all`
Expected: 全绿

- [ ] **Step 9: 提交**

```bash
git add -A
git commit -m "feat: 应用状态计算与总览页

版本漂移排在所有状态之前——它意味着「部署没做完」，且在 CLI 下
极难发现，是面板相对 CLI 最有说服力的增量。

已停止的旧版本不算进漂移判断（那是回滚候选）。每个状态都带文字
标识，不只靠颜色。"
```

---

## Task 11: 失联呈现与数据年龄（故障注入）

**Files:**
- Modify: `app/services/managed_app_status.rb`
- Modify: `app/views/overviews/_grid.html.erb`
- Create: `app/views/managed_apps/_host_table.html.erb`
- Modify: `app/views/managed_apps/show.html.erb`
- Create: `test/services/collectors/host_down_test.rb`
- Create: `test/system/unreachable_host_test.rb`

**Interfaces:**
- Consumes: `ManagedAppStatus`（Task 10）
- Produces:
  - `ManagedAppStatus#last_known_rows` → Array<Hash>（失联主机回落到最近一次可达的观测）
  - `ManagedAppStatus#stale?(threshold: 3.minutes)` → Boolean

**这是 spec 9.3 要求的故障注入测试之一。** 若无此测试，「失联要显式呈现、不清空界面」就只是纸面承诺。

- [ ] **Step 1: 写故障注入测试**

`test/services/collectors/host_down_test.rb`：

```ruby
require "test_helper"

class Collectors::HostDownTest < ExecutionLayerTest
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
      ssh:
        user: deploy
        port: #{FakeHost::NODES.fetch("node-2")}
    YAML

    ManagedApp.create!(
      name: "blog-#{SecureRandom.hex(4)}", config_yaml: yaml, destination: "production",
      ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key)
    )
  end

  teardown do
    system("docker compose -f docker-compose.test.yml start node-2 >/dev/null 2>&1")
    30.times { break if FakeHost.ready?; sleep 1 }
  end

  test "机器停机后：写入 unreachable，且保留上一次已知状态" do
    FakeHost.seed_container(node: "node-2", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")

    app = build_app
    Collectors::ContainerCollector.call(app)

    assert_equal "aaaaaaa", ManagedAppStatus.new(app).versions.first

    # 故障注入：把机器停掉
    system("docker compose -f docker-compose.test.yml stop node-2 >/dev/null 2>&1")

    Collectors::ContainerCollector.call(app)

    status = ManagedAppStatus.new(app)

    assert_equal :unreachable, status.level
    assert_equal "aaaaaaa", status.last_known_rows.first[:version],
      "失联后必须保留上次已知状态，不能清空——否则无法区分「服务挂了」和「面板瞎了」"
  end
end
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bin/rails test test/services/collectors/host_down_test.rb`
Expected: FAIL —— `NoMethodError: undefined method 'last_known_rows'`

- [ ] **Step 3: 实现 last_known_rows 与 stale?**

在 `app/services/managed_app_status.rb` 的 public 区域加入：

```ruby
  STALE_THRESHOLD = 3.minutes

  # 失联的主机回落到它最近一次「可达」的观测。
  #
  # 绝不清空界面（spec 6.4）：让人能区分「服务挂了」与「面板瞎了」。
  def last_known_rows
    host_rows.map do |row|
      next row if row[:reachable]

      fallback = last_reachable_observation(row[:host])
      next row if fallback.nil?

      row.merge(
        version: fallback.version,
        docker_status: fallback.docker_status,
        health: fallback.health,
        stale_since: fallback.observed_at
      )
    end
  end

  def stale?(threshold: STALE_THRESHOLD)
    observed_at.nil? || observed_at < threshold.ago
  end
```

在 private 区域加入：

```ruby
    def last_reachable_observation(host)
      Observation
        .where(managed_app: managed_app, host: host, reachable: true)
        .where.not(container_name: nil)
        .order(observed_at: :desc)
        .first
    end
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `bin/rails test test/services/collectors/host_down_test.rb`
Expected: 1 run, 0 failures

该测试会真实停掉一个容器再启回来，耗时约 30-60 秒，属正常。

- [ ] **Step 5: 主机明细视图**

`app/views/managed_apps/_host_table.html.erb`：

```erb
<table class="host-table">
  <thead>
    <tr>
      <th>机器</th>
      <th>角色</th>
      <th>版本</th>
      <th>容器状态</th>
      <%# 容器在运行 ≠ 在接流量，两列必须分开（spec 8.2） %>
      <th>接流量</th>
      <th>采集</th>
    </tr>
  </thead>
  <tbody>
    <% status.last_known_rows.each do |row| %>
      <tr class="<%= "row-unreachable" unless row[:reachable] %>">
        <td><%= row[:host] %></td>
        <td><%= row[:role] || "—" %></td>
        <td><%= row[:version] || "—" %></td>
        <td>
          <%= row[:docker_status] || "—" %>
          <%= "（#{row[:health]}）" if row[:health].present? %>
        </td>
        <td><%= row[:routed] ? "是" : "否" %></td>
        <td>
          <% if row[:reachable] %>
            正常
          <% else %>
            <strong>失联</strong>
            <% if row[:stale_since] %>
              — 以下为 <%= time_ago_in_words(row[:stale_since]) %>前的状态
            <% end %>
            <% if row[:error].present? %>
              <br><small><%= row[:error] %></small>
            <% end %>
          <% end %>
        </td>
      </tr>
    <% end %>
  </tbody>
</table>
```

在 `app/views/managed_apps/show.html.erb` 末尾加入：

```erb
<h2>各机器状态</h2>

<% status = ManagedAppStatus.new(@managed_app) %>

<p class="data-age">
  <% if status.observed_at %>
    数据采集于 <%= time_ago_in_words(status.observed_at) %>前
    <%= "（已过期）" if status.stale? %>
  <% else %>
    尚未采集
  <% end %>
</p>

<%= render "host_table", status: status %>
```

- [ ] **Step 6: 在总览页标注失联**

在 `app/views/overviews/_grid.html.erb` 的「数据年龄」单元格中，把内容替换为：

```erb
        <td>
          <% if status.observed_at %>
            <%= time_ago_in_words(status.observed_at) %>前
            <% if status.stale? %>
              <strong>（已过期）</strong>
            <% end %>
          <% else %>
            从未采集
          <% end %>
        </td>
```

- [ ] **Step 7: 写系统测试**

`test/system/unreachable_host_test.rb`：

```ruby
require "application_system_test_case"

class UnreachableHostTest < ApplicationSystemTestCase
  setup do
    @app = ManagedApp.create!(
      name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )
  end

  test "失联的机器显示上次已知状态，而不是空白" do
    Observation.create!(
      managed_app: @app, host: "10.0.0.1", role: "web",
      container_name: "blog-web-production-aaaaaaa", version: "aaaaaaa",
      docker_status: "running", reachable: true, observed_at: 10.minutes.ago
    )
    Observation.create!(
      managed_app: @app, host: "10.0.0.1", reachable: false,
      error: "Net::SSH::ConnectionTimeout", observed_at: Time.current
    )

    visit managed_app_path(@app)

    assert_text "失联"
    assert_text "aaaaaaa", count: 1
    assert_text "前的状态"
  end
end
```

- [ ] **Step 8: 运行全部测试**

Run: `bin/rails test:all`
Expected: 全绿

- [ ] **Step 9: 提交**

```bash
git add -A
git commit -m "test+feat: 失联呈现（含真实停机的故障注入测试）

测试真的把 fake host 停掉，断言 UI 保留上次已知状态而不是清空。
没有这个测试，「失联要显式呈现」就只是纸面承诺（spec 9.3）。

容器状态与是否接流量分成两列——容器在运行不等于在接流量。"
```

---

## Task 12: Observation 清理与实时刷新

**Files:**
- Create: `app/jobs/prune_observations_job.rb`
- Modify: `config/recurring.yml`
- Modify: `app/jobs/poll_managed_app_job.rb`
- Modify: `app/views/overviews/show.html.erb`
- Modify: `app/controllers/overviews_controller.rb`
- Create: `test/jobs/prune_observations_job_test.rb`

**Interfaces:**
- Consumes: `Observation`、`ProxyTarget`
- Produces:
  - `PruneObservationsJob.perform_now` → Integer（删除行数）
  - 总览页通过 Turbo Stream 自动刷新

**保留期：** 14 天。这是 spec 第 11 节列为待定的项，此处定为 14 天——足够回溯两周内的状态变化，且 SQLite 体积可控。

- [ ] **Step 1: 写失败测试**

`test/jobs/prune_observations_job_test.rb`：

```ruby
require "test_helper"

class PruneObservationsJobTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(
      name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )
  end

  test "删除超过保留期的观测" do
    Observation.create!(managed_app: @app, host: "10.0.0.1",
                        docker_status: "running", observed_at: 20.days.ago)
    Observation.create!(managed_app: @app, host: "10.0.0.1",
                        docker_status: "running", observed_at: 1.day.ago)

    PruneObservationsJob.perform_now

    assert_equal 1, Observation.where(managed_app: @app).count
  end

  test "即使全部超期，也保留每台主机最近一条——否则界面会变空白" do
    Observation.create!(managed_app: @app, host: "10.0.0.1",
                        docker_status: "running", observed_at: 100.days.ago)
    Observation.create!(managed_app: @app, host: "10.0.0.1",
                        docker_status: "running", observed_at: 90.days.ago)

    PruneObservationsJob.perform_now

    remaining = Observation.where(managed_app: @app)

    assert_equal 1, remaining.count
    assert_in_delta 90.days.ago.to_i, remaining.first.observed_at.to_i, 60
  end

  test "同样清理 ProxyTarget" do
    ProxyTarget.create!(managed_app: @app, host: "10.0.0.1",
                        service_name: "blog-web-production", observed_at: 20.days.ago)

    PruneObservationsJob.perform_now

    assert_equal 0, ProxyTarget.where(managed_app: @app).count
  end
end
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bin/rails test test/jobs/prune_observations_job_test.rb`
Expected: FAIL —— `NameError: uninitialized constant PruneObservationsJob`

- [ ] **Step 3: 实现清理任务**

`app/jobs/prune_observations_job.rb`：

```ruby
# 清理过期的观测快照。
#
# Observation 只追加，因此必须有清理（spec 5.2）。
# 但每台主机的最近一条永远保留——否则长期失联的机器会从界面上
# 消失，而「上次已知状态」正是失联呈现所依赖的（spec 6.4）。
class PruneObservationsJob < ApplicationJob
  queue_as :default

  RETENTION = 14.days

  def perform
    prune(Observation, group_by: [ :managed_app_id, :host ]) +
      prune(ProxyTarget, group_by: [ :managed_app_id, :host ])
  end

  private
    def prune(model, group_by:)
      keep_ids = model.group(*group_by).maximum(:observed_at).map do |group_key, time|
        conditions = group_by.zip(Array(group_key)).to_h
        model.where(conditions).where(observed_at: time).pick(:id)
      end.compact

      model.where(observed_at: ...RETENTION.ago).where.not(id: keep_ids).delete_all
    end
end
```

`config/recurring.yml` 的 `production: &default` 下加入：

```yaml
  prune_observations:
    class: PruneObservationsJob
    schedule: every day at 4am
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `bin/rails test test/jobs/prune_observations_job_test.rb`
Expected: 3 runs, 0 failures

- [ ] **Step 5: 采集完成后广播刷新**

在 `app/jobs/poll_managed_app_job.rb` 的 `perform` 末尾（`rescue` 之前）加入：

```ruby
    broadcast_overview_refresh
```

并在类中加入私有方法：

```ruby
  private
    def broadcast_overview_refresh
      Turbo::StreamsChannel.broadcast_replace_to(
        "overview",
        target: "overview-grid",
        partial: "overviews/grid",
        locals: {
          managed_apps: ManagedApp.order(:name).to_a.tap { |apps|
            @statuses = apps.index_with { |app| ManagedAppStatus.new(app) }
          },
          statuses: @statuses
        }
      )
    end
```

- [ ] **Step 6: 页面订阅**

`app/views/overviews/show.html.erb` 改为：

```erb
<h1>总览</h1>

<%= turbo_stream_from "overview" %>

<div id="overview-grid">
  <% if @managed_apps.empty? %>
    <p>还没有接入任何应用。<%= link_to "接入一个", new_managed_app_path %></p>
  <% else %>
    <%= render "grid", managed_apps: @managed_apps, statuses: @statuses %>
  <% end %>
</div>
```

`app/views/overviews/_grid.html.erb` 的最外层 `<table>` 需要包在 `overview-grid` 内——由于上面的 `broadcast_replace_to` 直接替换 `#overview-grid`，需在 partial 顶部加上包裹元素。把 partial 的第一行改为：

```erb
<div id="overview-grid">
```

末尾加上：

```erb
</div>
```

并把 `show.html.erb` 中重复的 `<div id="overview-grid">` 去掉（改为直接渲染 partial），避免嵌套两层同 id。

- [ ] **Step 7: 保持 viewing 标记新鲜**

`app/controllers/overviews_controller.rb` 已在 `show` 中调用 `mark_viewed!`。为让长时间停留的页面持续续期，在 `app/views/overviews/show.html.erb` 顶部加入一个每 10 秒轮询一次的 Turbo Frame：

```erb
<%= turbo_frame_tag "viewing-heartbeat", src: overview_path(format: :turbo_stream), loading: :lazy, refresh: "morph" %>
```

若实现成本偏高，可退而求其次：在 `PollCadence::VIEWING_TTL` 内不续期即回落到 60s，属可接受行为。**该退路是明确允许的，不视为未完成。**

- [ ] **Step 8: 运行全部测试**

Run: `bin/rails test:all`
Expected: 全绿

- [ ] **Step 9: 手工验收**

```bash
docker compose -f docker-compose.test.yml up -d
bin/rails server
```

浏览器打开 `http://localhost:3000`：

1. 接入一个应用，deploy.yml 用 `test/fixtures/files/simple_deploy.yml` 的内容，把 `port` 改成 2201，SSH 私钥粘贴 `test/fake_host/id_ed25519` 的内容
2. 在 fake host 上造两个不同版本的容器：
   ```bash
   ssh -i test/fake_host/id_ed25519 -o StrictHostKeyChecking=no -p 2201 deploy@127.0.0.1 \
     'docker run -d --name blog-web-production-aaaaaaa --label service=blog --label destination=production --label role=web busybox sleep 3600'
   ```
3. 确认总览页在无需刷新的情况下出现该应用的状态

- [ ] **Step 10: 提交**

```bash
git add -A
git commit -m "feat: Observation 清理与总览实时刷新

保留期 14 天，但每台主机的最近一条永远保留——否则长期失联的机器
会从界面消失，而「上次已知状态」正是失联呈现所依赖的。

采集完成后经 Turbo Stream 广播刷新总览。"
```

---

## 自查记录

**Spec 覆盖检查（计划 01 范围内）：**

| Spec 章节 | 覆盖的任务 |
|---|---|
| 4 依赖的 Kamal 内部事实 | Task 1（版本下限断言）、Task 3（配置 API）、Task 7（标签与容器名）、Task 8（proxy list） |
| 5.1 存什么不存什么 | Task 4（roles/hosts 不落库，现解析） |
| 5.2 表结构 | Task 4（ManagedApp）、5（Credential）、7（Observation）、8（ProxyTarget） |
| 5.3 接入流程 | Task 4（粘贴解析）、5（凭据）、6（连通性探测） |
| 5.5 一个 App = 一份 yml + 一个 destination | Task 4 |
| 6.1 两个采集器 | Task 7、Task 8 |
| 6.2 复用 deploy.yml 的 SSH 配置 | Task 6 |
| 6.3 自适应节奏 | Task 9 |
| 6.4 失败与不一致显式呈现 | Task 7（unreachable 行）、Task 11（保留上次已知状态） |
| 6.5 成本控制 | Task 7（轮询只跑 docker ps）、Task 8（只跑 proxy list） |
| 7.6 解析即代码执行 | Task 3 |
| 8.1 版本漂移一等公民 | Task 10 |
| 8.2 三层结构（① 总览、② 应用页） | Task 10、Task 11 |
| 8.3 数据年龄常驻 | Task 11 |
| 8.6 状态不只靠颜色 | Task 10（label + 文字）、Task 11 |
| 9.1 不 mock SSH | Task 2 及其后所有执行层测试 |
| 9.3 故障注入（机器失联） | Task 11 |
| 9.6 fake_host 硬前置 | Task 2 |

**未覆盖（属计划 02/03）：** 5.4 hook 上报、7.1-7.5 执行与安全、7.7 危险操作确认、8.2 ③ 容器详情、8.4 回滚交互、8.5 自部署、9.3 剩余两个故障注入场景（锁冲突、上报但观测不到）、9.4 版本兼容矩阵。

**类型一致性检查：** `ManagedApp`（非 `Application`）全篇统一；`Kamal::ParsedConfig#ssh_options` 返回带符号键的 Hash，Task 6 按 `[:user]` / `[:port]` 取用一致；`Observation.latest_for` 在 Task 7 定义、Task 10/11 使用；`ManagedAppStatus#host_rows` 在 Task 10 定义、Task 11 扩展为 `last_known_rows` 并复用同样的键名。

**占位符扫描：** 无 TBD / TODO / “类似 Task N”。
