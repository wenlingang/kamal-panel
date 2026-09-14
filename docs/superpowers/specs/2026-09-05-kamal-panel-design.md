# kamal-panel 设计文档

日期：2026-09-05
状态：已评审通过，待转实施计划

---

## 1. 项目定位

**kamal-panel 是一个开源的 Kamal 控制面板**：跨多台服务器查看 Kamal 部署的应用状态，并执行回滚、重启、停止等运维操作。

定位为**认真运营的开源项目**（目标是别人愿意在生产环境使用），而非个人自用工具。

### 1.1 为什么存在这个项目

Kamal 官方明确不做 Web UI。issue [basecamp/kamal#1850](https://github.com/basecamp/kamal/issues/1850) 已关闭，维护者 djmb 回复：

> There's no plans to add something like this right now. In theory though it should be possible, though there's no central state stored anywhere so making it real time would be a challenge. It would need to be an app that ran somewhere with SSH access to all the hosts to pull their current status.

这段话提供了两个关键信息：官方不会做（项目不会被上游吃掉），以及核心技术难题已被点明（无中心状态，必须 SSH 去各 host 拉取）。

### 1.2 现有生态（2026-09-05 调研）

| 项目 | 形态 | star | 最后提交 | 判断 |
|---|---|---|---|---|
| [Shipyrd](https://github.com/Shipyrd/shipyrd) | 靠 Kamal hooks 被动接收部署事件 | 4 | 2026-09-01 | 已转向通用团队看板，只记录不能操作 |
| [kamal-ui](https://github.com/KernelTheory/kamal-ui) | 本地运行，包装本机 CLI，刻意无鉴权 | 0 | 2026-08-17 | 单人本地工具，非团队面板 |
| [kamalgui](https://github.com/kobaltz/kamalgui) | Docker + Tailwind | 4 | 2025-03-21（仅一天提交） | 已停止维护 |
| HQ / [lazykamal](https://github.com/shuvro/lazykamal) | TUI | -/12 | - | 终端工具，非 Web |
| [deployed](https://github.com/geetfun/deployed) | Rails mountable engine | 99 | 2023-10-26 | 已停止维护 |

**结论：不存在维护中的「跨多机 + 有鉴权 + 能执行操作」的 Web 面板。这是真实空缺。**

---

## 2. 范围

### 2.1 做什么

- 跨多台服务器、多个应用的部署状态总览
- 版本漂移检测（同一应用在不同 host 上版本不一致）
- 容器状态与 kamal-proxy 路由状态分开呈现
- 回滚到历史版本、重启、停止、启动
- 日志查看、容器详情
- 多用户、两种角色（viewer / operator）、审计日志

### 2.2 明确不做（non-goals）

| 不做 | 原因 |
|---|---|
| **构建与发布新版本** | 面板不碰源码。新版本由 CI（GitHub Actions）build + push + deploy |
| **git 集成** | deploy.yml 手动粘贴。面板中不存在任何 git 凭据 |
| **`kamal app exec` / 任意 shell** | 一旦提供，面板即等价于带 Web 界面的远程 shell，全部安全设计作废。这是刻意的缺失，不是待办 |
| **细粒度 RBAC / SSO** | v1 只有 viewer / operator 两种角色。注意：新建 Application 等价于代码执行，仅 operator 可为之（见 7.6）|
| **agent** | 见 3.1 |
| **超过 50 台机器的规模** | 见 3.4 |
| **Kamal 1.x** | 只支持 Kamal 2+。1.x 用的是 Traefik 而非 kamal-proxy，路由状态、锁、容器标签模型均不同，兼容它等于维护两套采集与执行路径。README 写明最低版本 |

### 2.3 关键的能力分界

Kamal 的命令天然分成两类：

- **需要源码**：`kamal deploy`（要 Dockerfile 去 build）
- **只需要 deploy.yml**：`kamal rollback` / `app boot|stop|restart` / `app logs` / `app details` / `kamal details`

kamal-panel 只做后者。这条缝是整个项目的边界，也是「不碰源码」得以成立的技术基础。

---

## 3. 架构

### 3.1 状态获取：agentless SSH 拉取 + 可选 hook 推送

**已评估并否决的方案：每台机器部署 agent。**
理由：Kamal 用户选择 Kamal 正是为了避免装 agent；且 agent 若要能执行回滚，等于在每台机器上开一个具备 Docker 权限的远程执行端口，安全模型比 SSH 更差；接入门槛高，不利于开源采用。

**采用的方案：**

1. **SSH 拉取（主）** —— 回答「现在真实跑着什么」。零侵入：交出 deploy.yml 即可接入，服务器上不装任何东西，被管项目一行代码不改。
2. **Kamal hooks 推送（可选增强）** —— 回答「发生过什么」。用户自愿在自己项目的 `.kamal/hooks/post-deploy` 放一个脚本上报，即可获得含 commit、操作人、成败的准确部署事件，无需轮询。CI 中执行 `kamal deploy` 时同样触发。

两者渐进：不配 hook 也能完整使用，配了体验更好。

### 3.2 核心原则：机器是唯一真相来源

**面板的数据库只是缓存 + 历史 + 审计。** 任何时候面板显示的状态与机器不一致，以机器为准，且 UI 必须能看出这份数据的采集时间。

面板不维护任何「期望状态」——那正是同类项目的常见死因。

### 3.3 两套数据源的对账

hook 说部署成功，但 SSH 观测不到该版本运行，这种矛盾**必须显式呈现**，而不是挑一个信任。见 6.4。

### 3.4 规模上限

本设计的目标规模为 **50 台机器以内**。超出后每轮轮询的 SSH 扇出会成为瓶颈，那时才轮到 agent 方案。

**这句话要写进 README。** 说清边界比假装无限扩展更可信。

---

## 4. 依赖的 Kamal 内部事实

**验证基线：kamal v2.12.0（2026-06-18 发布）+ kamal-proxy v0.10.0。**

以下均于 2026-09-05 逐条从该版本 tag 的源码读出，非推测、非记忆。这些是整份设计的地基，Kamal 升级时需重新验证（见 9.4 版本兼容矩阵）。

| 事实 | 出处 |
|---|---|
| 容器标签为 `service` / `destination` / `role` | `lib/kamal/commands/app.rb` `container_filters` |
| 容器名格式 `service-role-destination-VERSION` | `lib/kamal/commands/app.rb` `extract_version_from_name` |
| `docker ps --all` + label 过滤可一并取回**已停止**的旧版本容器 | `lib/kamal/commands/app.rb` `list_versions(statuses: nil)` |
| 配置入口 `Kamal::Configuration.create_from(config_file:, destination:, version:)` | `lib/kamal/configuration.rb` |
| 配置对象暴露 `servers` / `roles` / `registry` / `ssh` / `sshkit` / `proxy` 等 | 同上 attr_reader |
| 命令生成 `Kamal::Commands::App.new(config, role:, host:)` | `lib/kamal/commands/app.rb` |
| hook 环境变量 `KAMAL_RECORDED_AT` / `KAMAL_PERFORMER` / `KAMAL_VERSION` / `KAMAL_SERVICE` / `KAMAL_SERVICE_VERSION` / `KAMAL_DESTINATION` | `lib/kamal/tags.rb` |
| proxy 操作模式为 `docker exec <proxy容器> kamal-proxy <cmd>` | `lib/kamal/commands/app/proxy.rb` |
| kamal-proxy 提供 `list --json`（别名 `ls`，RPC 调 `kamal-proxy.List`） | kamal-proxy v0.10.0 `internal/cmd/list.go` |
| 部署锁是 primary host 上的一个目录（`mkdir` 原子性），内容 base64 编码 message 与 version | `lib/kamal/commands/lock.rb` |
| `kamal rollback VERSION` 先 `container_available?` 逐 host 逐 role 检查容器是否存在，**不存在直接拒绝，不会去 registry 拉镜像** | `lib/kamal/cli/main.rb:87` |

---

## 5. 数据模型与接入

### 5.1 存什么、不存什么

deploy.yml 中已有的内容（servers、roles、registry、proxy 配置）**一律不落库为表字段**，每次用 `Kamal::Configuration` 现场解析。落库等于抄一份会漂移的副本，而 deploy.yml 才是用户真正维护的东西。

数据库只存三类：**接入信息、观测记录、发生过的事**。

### 5.2 表结构

```
Application    name, config_yaml, destination_config_yaml, destination, ssh_credential_id
               ↳ servers/roles/registry 均从两份 yaml 现场解析，不存字段
               ↳ destination_config_yaml 为可选的 deploy.<destination>.yml 原文（见 5.5）

Credential     kind(ssh_key), encrypted_value
               ↳ Rails 8 ActiveRecord encryption

Observation    application_id, host, role, container_name, version,
               docker_status, health, observed_at
               ↳ 不可变，只追加。每轮轮询写新行，绝不 UPDATE 旧行

DeployEvent    application_id, version, performer, destination,
               command, status, recorded_at, source(hook|inferred)

AuditLog       user_id, application_id, action, target_version, hosts,
               command, output_digest, result, duration_ms, created_at
               ↳ 不可删除，UI 不提供删除入口

User           email, password_digest, role(viewer|operator)
```

**设计要点：**

- `AuditLog` 与 `DeployEvent` 必须分开：前者是「谁在面板上点了什么」，后者是「机器上发生了什么」。二者不是一回事，混在一起会让事后追查失去意义。
- `Observation` 只追加：使「14:32 running → 14:35 unhealthy」天然可查，并让 UI 能诚实显示数据年龄。代价是需要保留 N 天的清理任务。
- **无 `registry_credential_id`**：见 7.1，回滚路径上用不到 registry 凭据。

### 5.3 接入流程

用户新建 Application 时三步，全程零改造：

1. **粘贴 deploy.yml 原文**，以及——若使用了 destination——**再粘贴一份 `deploy.<destination>.yml`**（可选，见下）→ 在**受限子进程**中用 `Kamal::Configuration.create_from` 解析（见 7.6，这一步是代码执行）→ 当场展示「解析出 N 个 role、M 台 host、registry 为 X」供用户确认。解析失败即失败，不做猜测。
2. **配置 SSH 凭据** → 立即对所有 host 做连通性探测，逐台列出成功/失败。
3. 完成。服务器上没装任何东西，被管项目一行代码没改。

### 5.4 可选的 hook 上报

面板生成一段脚本（含面板 URL 与 per-application token），用户自愿放入 `.kamal/hooks/post-deploy`：

```sh
#!/bin/sh
curl -sf -X POST "$PANEL_URL/api/deploys" \
  -H "Authorization: Bearer $PANEL_TOKEN" \
  -d service="$KAMAL_SERVICE" -d version="$KAMAL_VERSION" \
  -d performer="$KAMAL_PERFORMER" -d destination="$KAMAL_DESTINATION" \
  -d recorded_at="$KAMAL_RECORDED_AT" -d command="$KAMAL_COMMAND" || true
```

**结尾的 `|| true` 是硬性要求：面板挂掉绝不能导致用户的部署失败。** 这条必须写进 README，否则没人敢加这个 hook。

> 本节的完整设计见子设计 `2026-09-07-kamal-panel-hook-reporting-design.md`（计划 03 实施）。

### 5.5 边界定义

**一个 Application = 一份 deploy.yml +（可选）一份 destination 覆盖文件 + 一个 destination 名。** 同一个 repo 部署到 staging 与 production 即为两个 Application——这是 Kamal 自身的模型（`--destination` 会进入容器标签与容器名）。面板不发明新抽象。

**为什么需要第二份文件**（2026-09-05 实施 Task 3 时发现，源码核实）：Kamal 的 `load_raw_config`（`configuration.rb:28-30`）在传入 destination 时，会把 `deploy.<destination>.yml` **deep-merge** 到 `deploy.yml` 之上：

```ruby
def load_raw_config(config_file:, destination: nil)
  load_config_files(config_file, *destination_config_file(config_file, destination))
end
```

真实项目正是在这份文件里放 per-destination 覆盖，**其中最常见的就是不同的 `servers`**。因此只拿 `deploy.yml` 去解析一个带 destination 的应用，会丢掉全部覆盖——面板会去轮询错误的机器。这不是外观问题。

该文件是**可选**的：destination 为空时不需要；有 destination 但没有覆盖文件时也可留空。

---

## 6. 状态采集

### 6.1 两个采集器

**Host 采集器**（每台机器一次，所有 Application 共享）：

```
docker exec kamal-proxy kamal-proxy list --json
```

取回该机器 kamal-proxy 的完整路由表：哪个 service 为 live、target 指向哪个容器、TLS 状态。

**这是唯一能回答「用户访问域名时流量实际到达哪个容器」的数据源。容器在运行 ≠ 在接流量，`docker ps` 看不出这件事。**

**实测输出形态（kamal-proxy v0.10.0，2026-09-05 对运行中实例观测，非源码推断）**：它是一个**以服务名为键的对象**，而不是数组：

```json
{
  "blog-web-production": {
    "targets": ["blog-web-production-aaaaaaa:80"],
    "state": "running"
  }
}
```

第 4 节那 12 条 Kamal 事实是读源码得来的，而这一条最初也是从 `internal/cmd/list.go` 推断的——推断的形态是「数组，每项带 `service` 字段」，**与实测不符**。教训：`list.go` 打印的是 `response.Targets`，但该字段本身是个 map，从打印语句读不出这一层。

因此：**同一 host 上的其他应用也会出现在同一份 payload 里**，需按 `roles[*].container_prefix` 挑出属于本应用的键；且该输出形态不保证跨版本稳定，`ProxyTarget.raw` 列保存原始 JSON 正是为此——遇到无法识别的形态时存原文，不丢弃该 host 的数据。

**Application 采集器**（每 Application × 每 host 一次）：

```
docker ps --all \
  --filter label=service=<service> \
  --filter label=destination=<destination> \
  --format '{{json .}}'
```

一条命令取回所有 role（role 从 label 读取，不按 role 分别查询）。`--all` 是关键：已停止的旧版本容器一并返回，**即为回滚候选列表**，面板无需自建版本历史。

### 6.2 连接复用用户自己的配置

直接使用 Application 的 deploy.yml 中的 `ssh:`（user / port / proxy_jump）与 `sshkit:` 配置喂给 SSHKit。

这条不起眼但重要：**用户配置的跳板机、非标准端口、专用 deploy 用户，面板全部自动继承**，不需在面板中重复配置，也不会出现「kamal 能连、面板连不上」。

**但跳板机的继承有两条硬性限制**（2026-09-05 实施 Task 6 时发现，net-ssh 7.3.3 源码核实）：

`Net::SSH::Proxy::Jump` 是 `Net::SSH::Proxy::Command` 的子类。它把跳板机规格拼成一条 shell 命令行（`ssh -l <user> -p <port> -J <extra_jumps> -W %h:%p <host>`），再由 `Command#open` 交给 `IO.popen` 执行。其中 `extra_jumps` 取自 `jump_proxies.split(",", 2)[1]`，**原样插值、不经任何解析**。

因此，一份粘贴的 deploy.yml 若含 `ssh.proxy: "user@bastion,x; <任意命令>"`，会在**面板宿主机上**执行该命令——发生在接入时的连通性探测期间，且在面板自身进程里、无任何边界约束。这比 7.6 中已被子进程边界约束住的 ERB 求值严重得多。

据此：

- **`ssh.proxy_command` 一律拒绝**，并给出明确提示。它的语义本身就是「执行这条本地命令」，无法被安全化。这是永久的产品决策，不是 v1 限制。
- **`ssh.proxy` 仅支持单跳**：含逗号即拒绝（`extra_jumps` 正是未转义的注入点），其余部分按 `[user@]host[:port]` 以保守字符集校验。沿用 Kamal 自身的默认规则：不含 `@` 时用户名按 `root` 处理。
- 代理对象**在父进程中构造**，不跨 JSON 子进程边界传递——代理是活对象，序列化后只会得到 `"#<Net::SSH::Proxy::Jump:0x...>"` 这种无用字符串。

**校验 `ssh.proxy` 并不足以关闭这个面。** 一旦代理对象是真实的，`Command#open` 的 `IO.popen` 就会被执行，而它的命令行模板还要代入 `%h`（主机）与 `%p`（端口）：

```
ssh -l <user> -p <port> -J <extra_jumps> -W %h:%p <host>
                                            ↑    ↑
                                      来自 servers: 与 ssh.port
```

`servers:` 的主机与 `ssh.port` 同样来自粘贴的 deploy.yml，而 Kamal 对二者只做类型检查、不做字符集检查（其文档中 port 的示例本身就是字符串 `"2222"`）。因此 `servers: web: ["1.2.3.4 ; <任意命令> #"]` 会经由同一条 `IO.popen` 执行。

**所以以下三项都必须校验，缺一不可**：`ssh.proxy`、`servers:` 中的每个主机、`ssh.port`。主机按保守的主机名/IP 字符集校验（并禁止前导 `-`，否则会被 ssh 当作选项，构成参数注入），端口强制为整数。

这条教训值得记住：**关掉一扇门，可能让门后的走廊变得可通行**——修好 proxy 之前，`IO.popen` 因为序列化 bug 而根本到不了。

同一 host 被多个 Application 使用时，合并进单个 SSH 会话批量执行，不为每个 app 各建一次连接。

### 6.3 自适应节奏

| 情况 | 间隔 |
|---|---|
| 无人查看 | 60s |
| 有浏览器正在查看该 app | 10s |
| 刚完成操作 / 刚收到 hook 事件 | 2s，持续 90s 后回落 |

结果经 Turbo Streams 推送给已打开的页面。无人查看时不应消耗 SSH 连接。

### 6.4 失败与不一致必须显式呈现

- **机器连不上** → 写入 `status=unreachable` 的 Observation，**绝不清空界面**。UI 显示上次已知状态 +「6 分钟前」+ 红色标记。
  > 最糟的面板行为是机器一失联就显示「无数据」，使人无法区分「服务挂了」与「面板瞎了」。

- **hook 报告成功但观测不到** → 收到 DeployEvent 后触发 burst 轮询；90s 内若无任何 host 观测到该 version 处于 running，UI 挂出明确告警：「v3f9a2 已上报部署成功，但未在任何机器上观测到」。
  > 这是双数据源方案的固有代价。处理方式是把矛盾摆到台面上，而不是挑一个来信任。

### 6.5 成本控制

轮询路径只执行 `docker ps` 与 `kamal-proxy list`，均为小 payload。`docker inspect`（完整健康检查日志）**仅在用户点开容器详情时按需执行**，不进入轮询循环。

---

## 7. 执行与安全

### 7.1 回滚的真实语义

`kamal rollback VERSION`（`lib/kamal/cli/main.rb:87`）先调用 `container_available?` 逐 host 逐 role 检查该 version 的**容器**是否存在，不存在则直接拒绝，**不会去 registry 拉取镜像**。

因此：

- **回滚 = 重启一个仍留在机器上的已停止容器**
- **registry 凭据在回滚路径上完全用不到**，v1 不需要该字段与该配置步骤

**这也正是面板能真正超过 CLI 的地方**：面板的轮询数据里已有全量 `docker ps --all` 结果，可以计算出「哪些 version 在所有 host 的所有 role 上都还存在」。CLI 是试了才告诉你不行；面板**只列出真正可回滚的版本**，其余置灰并注明原因（如「node-2 上已被清理」）。

### 7.2 SSH 私钥：项目的责任上限

**面板的安全等级 = 用户所有服务器的安全等级。这句话放在 README 第一屏，不藏在文档深处。**

v1 方案：私钥加密存库（Rails 8 ActiveRecord encryption，主密钥只从环境变量读取、不落盘），配四条硬约束：

1. **只写不读**：UI 永不回显私钥、不提供下载，编辑只能整体替换
2. **使用专用 deploy 用户，不用 root**：Kamal 本身只要求 SSH 用户在 docker 组内，面板不需要更高权限
3. **建议在 `authorized_keys` 中加 `from=<面板IP>`** 限制来源，文档给出可复制的原文
4. 私钥与 Application 一对一，单个应用泄漏不牵连其他

已评估并推迟的方案：挂载宿主 `SSH_AUTH_SOCK` 委托 ssh-agent（私钥不落面板磁盘）。因面板重启后需人工重新提供，对长期无人值守运行的服务不现实。列为后续可选项。

### 7.3 执行模型：封闭动作集

面板**永远不执行任意命令**。动作集是封闭的：

| Action | 角色 | 需要锁 | 说明 |
|---|---|---|---|
| `rollback` | operator | ✅ | 仅对 7.1 算出的可回滚版本开放 |
| `restart` / `stop` / `start` | operator | ✅ | |
| `force_unlock` | operator | — | 见 7.4 |
| `logs` / `details` / `inspect` | viewer | ❌ | 只读 |

每个 Action 是一个类，声明：所需角色、是否需要锁、影响哪些 host、如何用 `Kamal::Commands::App` 生成命令、如何判定成功。

### 7.4 复用 Kamal 自己的部署锁

Kamal 的部署锁是 primary host 上的一个目录（依赖 `mkdir` 的原子性），锁内容 base64 编码了 message 与 version。

- 面板执行任何变更前**必须获取同一把锁**，否则会与 CI 中正在运行的 `kamal deploy` 冲突——在本项目设定的架构下（发布归 CI）这是常态。
- 反向白得一个功能：**UI 显示锁状态**。CI 正在部署时，回滚按钮置灰并显示「部署进行中，持有者 xxx」。纯读操作，实现成本接近零。
- 拿不到锁即明确报错，**绝不自动 `--force`**。
- **强制解锁 v1 提供**（否则用户遇到 CI 崩溃遗留的死锁只能去 SSH，体验很差），但需：operator 角色 + 手输应用名确认 + 单独的审计标记。

### 7.5 审计：先写后做

AuditLog 在**动作发起前**即落一条 `pending`，执行完成后更新结果。这样即便面板中途崩溃，也留下「有人发起过回滚」的痕迹——事后追查时，「没有记录」与「记录显示中断」是完全不同的信息量。

记录内容：操作人、动作、应用、目标版本、影响的 host 列表、实际生成的命令、stdout/stderr 摘要、耗时。

**审计日志不可删除，UI 不提供删除入口。**

### 7.6 解析 deploy.yml 是代码执行，必须隔离

`Kamal::Configuration.load_config_file`（v2.12.0，`configuration.rb:37-47`）：

```ruby
template = File.read(file)
rendered = ERB.new(template, trim_mode: "-").result
YAML.send(load_method, rendered).symbolize_keys   # load_method = :unsafe_load
```

deploy.yml 先经 **ERB 求值**，再经 **`YAML.unsafe_load`**。两条都是任意代码执行路径。

Kamal 这样做本身完全合理——它假定该文件是你本机上你自己的文件。但 kamal-panel 把它变成了一个 **Web 表单输入**，性质就变了：**粘贴 deploy.yml ≡ 在面板进程中执行任意 Ruby。**

**不能通过换用 `YAML.safe_load` 绕开**——那会丢掉 ERB 支持（真实世界的 deploy.yml 大量使用 ERB 注入版本号、镜像名、环境变量），也就丢掉了「直接复用 kamal gem」这一技术栈决策的核心价值。

因此采取两层处理：

1. **在受限子进程中解析。** 解析不在 Web 进程或任务进程内进行，而是 fork 一个短生命周期的子进程执行，只将解析结果以 JSON 回传。子进程约束：硬超时（5s）、内存上限、非特权用户运行。子进程崩溃或超时即视为「这份 deploy.yml 无法解析」，不影响面板本体。
2. **把它确立为显式的信任边界。** 新建/编辑 Application **仅限 operator 角色**，viewer 不可为之。README 与新建页面均需写明：**能新建 Application 的人，等价于能在面板宿主机上执行代码。**

这条同时约束 5.3 的接入流程：粘贴 deploy.yml 后的「当场解析并展示 role/host/registry」这一步，走的就是这个受限子进程。

### 7.7 危险操作的确认

- `rollback` / `stop` / `force_unlock` 需要 operator 角色 **+ 手输应用名确认**
- **viewer 角色看不到按钮，而不是看到置灰的按钮**——后者会诱导用户追问「为什么我不能点」

---

## 8. 界面

### 8.1 版本漂移是一等公民

Kamal 滚动部署中途失败会留下 **host A 运行 v3、host B 仍是 v2** 的状态。CLI 下极难发现：需逐台 `kamal app details` 再人肉比对容器名后缀。而面板每轮轮询天然持有全量数据，**统计 distinct version 数量即可判定**。

这是面板相对 CLI 最有说服力的增量价值，因此它是总览页的一等公民，不是角落里的某个功能。

### 8.2 三层结构

**① 总览** —— 目标：3 秒内回答「有没有东西挂了」

Application × Host 的网格，每格一个状态点。优先级从高到低：

| 状态 | 含义 |
|---|---|
| 🔴 版本漂移 | 同一 app 在不同 host 上版本不一致——排最前，意味着「部署没做完」 |
| 🔴 容器异常 | not running / unhealthy |
| 🟡 机器失联 | 显示上次已知状态 + 失联时长 |
| 🟢 正常 | 版本一致、全部 running、proxy 路由正常 |

**② 应用页** —— 单个 app 的全貌

- 每个 (host, role) 当前运行的版本，不一致时高亮
- **路由状态**（来自 `kamal-proxy list --json`）：容器在运行 ≠ 在接流量，这两列分开显示
- 部署历史（DeployEvent + 从 Observation 推断的版本变更）
- 回滚入口

**③ 容器详情** —— 按需拉取

`docker inspect`、健康检查日志、容器日志 tail。均不进入轮询循环，点开才执行。

### 8.3 数据年龄始终可见

每个视图固定位置显示「12 秒前更新」；失联的 host 单独标红并显示上次成功采集时间。

**绝不让页面看起来是实时的、实际却是 5 分钟前的。** 面板一旦让人产生「我看到的就是现在」的错觉，出事时比没有面板更糟。

### 8.4 回滚交互（四步）

1. **选版本** —— 只列出真正可回滚的（7.1），其余置灰并注明原因
2. **确认影响面** —— 明确列出将操作哪些 host、哪些 role，以及当前锁状态
3. **手输应用名确认**
4. **执行过程实时流式输出** —— SSH 的 stdout/stderr 逐行经 Turbo Stream 推送到页面

第 4 步是硬要求。**不能是一个转圈动画然后告知「成功了」**——运维操作出问题时，人需要看到卡在哪一步。执行结束后自动触发 burst 轮询，用新的 Observation 确认结果，而**不是拿命令退出码当结论**。

### 8.5 技术选择

**Rails 8 默认栈：Hotwire（Turbo + Stimulus）+ Solid Queue + Solid Cable，不引入任何前端框架。**

理由不是偏好而是部署形态：面板要能单容器跑起来，不需要 Redis，不需要独立的前端构建产物。**一个面板项目如果自己就难部署，是没有说服力的。**

配套：**面板用 Kamal 部署自己**，仓库内附可直接使用的 `deploy.yml` 与 hook 范例。在这个项目上 dogfooding 不是姿态，是最基本的可信度。

### 8.6 视觉方向：37signals 设计语言

参考对象：[Basecamp](https://basecamp.com/)（**主要参考**）、[ONCE](https://once.com/)、[HEY](https://www.hey.com/)、[Fizzy](https://www.fizzy.do/)。

选它们除了审美，还有一层合理性：**Kamal 本身就是 Basecamp 的产物**，面板与它气质一致是恰当的。

#### 一个必须先说清的张力

上述参考大多是**营销页**：大留白、低密度、内容优先。而 kamal-panel 的总览页是**运维仪表盘**，天然要求高密度、一眼看全。**直接照搬营销页的版式会是灾难。**

因此本项目继承的是它们的**原则**，不是版式：

| 原则 | 在本项目中的落地 |
|---|---|
| **克制用色** | 颜色只用来表达状态，绝不用于装饰。界面主体是中性灰白，全屏可能只有 3-5 个彩色像素块——但那几个块一定是「有东西挂了」 |
| **扁平，无装饰** | 不用阴影、渐变、玻璃拟态。层级靠**留白与边框**建立，不靠 elevation |
| **排版建立层级** | 字重与字号负责层级，不靠颜色。正文字号不小气（≥15px），运维界面要能长时间盯着看 |
| **真实的文案** | 错误信息说人话。不写「操作失败」，写「node-2 SSH 连接超时（30s），上次成功是 6 分钟前」 |
| **按钮朴素** | 扁平、小圆角、无阴影。主操作靠位置和文案突出，不靠视觉噪音 |
| **衬线用于引述** | Basecamp 用衬线体做客户引言。本项目对应的场景是**只读的机器原文**——SSH 输出、锁持有者信息、hook 上报内容，用等宽体承担同类角色：一眼可辨「这是机器说的，不是界面说的」 |

#### 颜色语义（硬规则）

状态色是这个产品的核心信息载体，因此单独定死：

- 全站只有**四个状态色**，对应 8.2 那张表（漂移 / 异常 / 失联 / 正常），不再引入第五种
- **状态绝不能只靠颜色传达**。每个状态点必须同时具备形状或文字标识——色觉障碍用户必须能用这个面板做回滚决策
- 状态色在浅色与深色主题下都需通过 WCAG AA 对比度检查
- 品牌色（如果有）不得与任何状态色相近

#### 密度

- **总览页**：紧凑。这是唯一为密度让步的页面，目标是一屏看完所有应用 × 所有机器
- **应用页与详情页**：回归参考对象的从容留白，这里是读信息的地方，不是扫状态的地方

#### 深色模式

支持。运维人员会长时间盯着这个界面，且常在夜间处理故障。但四个状态色必须在两个主题下**分别**做对比度验证，不能只把亮色主题反转。

**已实施**（2026-09-10）。跟随系统的 `prefers-color-scheme`，不提供手动开关——系统主题就是用户的意图，面板不必再问一遍。全部颜色收进 `:root` 的自定义属性，深色主题重新给值而非反转。

那句「分别做对比度验证」落成了测试而不是承诺：`test/assets/color_contrast_test.rb` 解析样式表里的两套调色板，按 WCAG 2.1 公式对 8 对实际同屏出现的前景/背景断言 ≥ 4.5:1（状态徽章是 0.85rem 的正文档次，不适用 3:1 那档大字标准），并断言两套定义了同一组变量——否则深色下会有变量悄悄回落到浅色值。改坏任何一个状态色，这条测试会报出具体是哪一对、比值多少。

实测最紧的两处：浅色 `--unknown-ink` 4.67:1，深色 `--ink-muted` 5.90:1。

---

## 9. 测试策略

### 9.1 不 mock SSH

本项目的本质就是「与真实机器交互」。把 SSH 层 mock 掉，测试会全绿，而所有真实 bug 都藏在被 mock 掉的部分里。

执行层测试跑在**真正 SSH 进去的假服务器**上：一个 `fake_host` 镜像（sshd + docker CLI），docker-compose 起 2-3 个，面板真的连进去、真的执行 `docker ps`。

这套设施同时是**场景夹具**：「版本漂移」场景即在两个 fake host 上分别启动容器名 version 后缀不同、`service`/`destination` label 相同的容器。**场景用数据构造，不用 stub 构造。**

### 9.2 三层

| 层 | 测什么 | 数量 |
|---|---|---|
| **命令生成** | `Kamal::Commands::App` 给定 config/role/host 产出的命令数组——纯函数、零 IO、断言字符串 | 最多 |
| **SSH 执行** | 连接真实 fake host，执行真实 docker 命令，解析真实输出 | 中等 |
| **系统测试** | Capybara 走完整回滚流程，跑在同一套 fake host 上 | 少量 |

命令生成层看似简单但价值最高：**Kamal 升级导致的破坏会在这一层第一时间暴露**，而不是等用户在生产上发现回滚按钮点了没反应。

### 9.3 故障注入是一等公民

以下三个场景必须有测试，它们正对应设计中最容易做错的三处：

| 场景 | 构造方式 | 断言 |
|---|---|---|
| **机器失联** | `docker stop` 掉一个 fake host | UI 显示 unreachable 且**保留**上次已知状态，不清空 |
| **锁冲突** | 在 fake host 上手动 `mkdir` 出锁目录 | 回滚按钮置灰、执行被拒、显示持有者 |
| **上报了但观测不到** | POST 一个 DeployEvent 但不实际启动容器 | 超时后出现矛盾告警（`test/system/deploy_reconciliation_test.rb`） |

**若这三项没有测试，6.4 与 7.4 中那些「显式呈现不一致」的设计就只是纸面承诺。**

### 9.4 Kamal 版本兼容矩阵

CI 中针对多个 kamal gem 版本运行（当前版本 + 上一个 minor）。这是「直接引 gem」方案的必付成本，**必须在 CI 自动暴露**，而不是等用户报 issue 说「升级 Kamal 后面板全炸」。

**已实施**（`compat_matrix` 作业）。三处值得记下的决定：

- 版本经 `KAMAL_VERSION` 注入 Gemfile；当前锁定版本由主 `test` 作业覆盖，矩阵只跑上一个 minor，不重复。
- 作业里**先断言真的装上了被测版本，这一步不允许失败**。若注入哪天失效，矩阵会静默地又跑一遍当前版本并永远显示绿色——一个什么都没测却永远通过的作业，比没有这个作业更糟。
- `continue-on-error` 只加在**跑测试那一步**上，不加在作业上：矩阵自己坏了必须吵，被测版本上的不兼容只需被看见。

2026-09-08 对 kamal **2.11.0** 实测：294 个单元用例与 32 个 system 用例全部通过，唯一的失败是本项目自己那条「版本不低于 2.12」的下限断言——它在矩阵里必然失败且不携带新信息，因此只在未显式指定 `KAMAL_VERSION` 时才生效。也就是说面板当前对 2.11.0 **行为上完全兼容**，第 4 节那 12 条从 v2.12.0 源码读出的事实，在 2.11.0 上同样成立。

### 9.5 明确不测

不测 Kamal 自身逻辑（假定 gem 是正确的）、不搭建 SSH mock 框架、不追求覆盖率数字。

### 9.6 开发顺序的硬前置

按 TDD 推进，但有一条硬约束：**`fake_host` 夹具必须在写第一个执行层测试之前就位**。否则第一个测试必然退化为 mock，此后整个项目再也回不来。

---

## 10. 技术栈汇总

| 层 | 选择 | 理由 |
|---|---|---|
| 语言/框架 | Ruby on Rails 8 | 可直接 `require "kamal"` |
| Kamal 集成 | **直接引 kamal gem** | 复用其 Configuration 解析、Commands 生成、SSHKit 连接池，而非 shell out 拼命令行再正则解析输出；Kamal 升级跟随成本低；社区重叠度高，潜在贡献者多 |
| 前端 | Hotwire（Turbo + Stimulus） | 单容器部署，无独立前端构建 |
| 后台任务 | Solid Queue | 无需 Redis |
| 实时推送 | Solid Cable | 无需 Redis |
| 数据库 | SQLite（默认）/ PostgreSQL（可选） | 单容器起步 |
| 加密 | Rails 8 ActiveRecord encryption | 主密钥只从 ENV 读 |
| 分发 | Docker 镜像 + 自带 deploy.yml | 非 Ruby 用户不受影响 |

---

## 10.1 已知限制

- **轮询去重的原子性依赖 SQLite。** 调度器用缓存的原子占位（`write` 配 `unless_exist: true`）避免同一应用被重复入队。该保证在 SolidCache + SQLite 上成立，但成立的原因是 SQLite 的**全局单写者串行化**，而非行级锁：`solid_cache` 的 `Entry.lock_and_write` 对已存在的行是真原子的，而一个键的**首次占位**靠的是 SQLite 让并发写彼此阻塞。

  因此，若将缓存换到 PostgreSQL 后端，首次占位可能重新出现竞争。后果是有界的——一次重复轮询（即原本要修的那个 bug），不会有数据损坏，也不会「再也不轮询」。但换库时应重新验证这一点，不要假定它自动成立。

  这条记录于此，是因为它的验证只在 `MemoryStore` 上做过，而那不是生产环境部署的 store。

### 10.2 本地验证实时刷新时的陷阱

dev 与 test 环境的 `config/cable.yml` 使用 `async` adapter，它【只在进程内有效】。

因此，用另一个进程（例如 `bin/rails runner`）去触发一次轮询，广播【永远不会到达浏览器】——验证者会得出「实时刷新不工作」的结论，而它其实是工作的。

正确的验证方式是让触发发生在【同一个 Puma 进程内】（例如 Rails 的 web console）。2026-09-05 实测确认可用：服务端日志出现 `[ActionCable] Broadcasting to overview` 与 `Turbo::StreamsChannel transmitting ... (via streamed from overview)`，浏览器中「数据年龄」单元格无刷新即更新。

（生产环境用 Solid Cable，不存在这个限制。）

另记一处开发环境的既有缺口：本地 dev 未配置 `active_record_encryption` 凭据时无法保存 SSH 私钥，因而无法走完人工接入流程。需先执行 `bin/rails db:encryption:init` 并写入该环境的 credentials。这一条应进 README 的开发环境说明。

### 10.3 状态模型的两处已知限制

**`level` 不包含 proxy 路由状态。** 本 spec 8.2 把 🟢 正常定义为包含「proxy 路由正常」，但计划 01 的实现未把 proxy 状态接入 `level`，且当时未记录理由。路由信息在应用页作为独立一列呈现（容器在运行 ≠ 在接流量），但它不会影响总览页的徽章。

把 proxy 状态纳入 `level` 是对状态模型的实质改动（要决定「容器健康但没接流量」算哪一档），应在后续计划中连同回滚等写操作一起设计，而不是在只读链路的收尾处顺手加入。

**SSH 不校验 host key。** `Collectors::SshSession` 使用 `verify_host_key: :never`。这是 v1 的显式取舍：面板没有 known_hosts 的管理界面，而在没有界面的情况下把校验打开只会让接入在首次连接时静默失败。代码中已标注为已知缺口。

后果要说清楚：面板无法察觉中间人替换目标主机。缓解依赖于面板与被管机器之间的网络本身可信（通常是同一 VPC）。补上 host key 固定应与鉴权一并设计。

### 10.4 陈旧阈值与跳板机 / 规模上限的相互作用

`STALE_THRESHOLD` 目前硬编码为 3 分钟，而空闲轮询节奏是 60 秒。`observed_at` 是每轮容器采集【开始时】打的单一时间戳，因此陈旧度衡量的是「距上次轮询开始过了多久」，峰值为 `max(60s, 轮询耗时)`。需要连续错过三轮才会触发；单台主机超时或单个采集器失败仍会写入新鲜时间戳，不会误触发。

**但它与本 spec 已宣传的两条性质相互作用**（2026-09-06 最终评审给出的量化分析）：

`capture_many` 是**串行**的，且每轮对每台主机开两条 SSH 会话。50 台机器即 100 次连接，要求每次 SSH 平均低于约 **1.8 秒**。局域网（0.2–0.5s）有 3–8 倍余量；但**经跳板机或高延迟链路**（握手 1–2s）时，一个**完全健康的 50 主机应用会长期显示黄色**——即在本 spec 同时承诺的「继承你的跳板机配置」（6.2）与「目标规模 50 台」（3.4）两个条件叠加时，陈旧指示会狼来了。

而狼来了正是这个指示存在所要防止的失败：一个长期发黄的指示会教会运维不再读它。

修法方向（属后续计划）：阈值应由 `PollCadence::IDLE` 或实测轮询耗时推导，而不是硬编码；或让 `capture_many` 并发化以压低单轮耗时。~~（已修复）

### 10.5 调用 kamal CLI 对既有 RCE 面的扩大（计划 02）

7.6 记录的事实是：解析 deploy.yml 等于执行任意 Ruby，因此计划 01 把它约束在**沙箱子进程**内——5 秒硬超时、只回传 JSON、崩溃即视为解析失败。

计划 02 决定写操作**调用真实的 kamal CLI**（理由见 12 决策记录）。这带来两处必须写明的扩大：

1. **ERB 求值的边界变宽了。** kamal 自己会 ERB-求值 deploy.yml，而这一次发生在 kamal 子进程中——**10 分钟超时、完整网络访问、可读写用户的服务器**，而不是那个 5 秒的沙箱。
2. **用户的 hook 脚本会在面板宿主机上执行。** Kamal 按 cwd 解析 `.kamal/hooks/*`，因此面板必须持有并写出这些脚本，kamal 随后在面板宿主机上运行它们。

**信任边界没有变**：这两件事都只对 operator 开放，而用户自己在本机跑 `kamal deploy` 时本来就是这样。但**暴露程度显著扩大**，所以：

- 新建应用的权限（operator）与「等价于在面板宿主机上执行代码」这条提示，比在计划 01 时更加名副其实
- 接入流程因此额外接受两份可选内容：`.kamal/secrets` 与 `.kamal/hooks` 的文件内容，二者均加密存储（hooks 按 5.4 的样例本身就携带 per-application token，属凭据材料）
- 不提供这两份内容时，用户的 hook 不会触发，且使用数组式密码写法的应用其 `app boot` / `rollback` 会失败——面板须如实说明，而不是让操作静默失败

## 11. 待定事项

以下在实施计划阶段决定，不阻塞本设计：

- 首次登录的初始化流程（环境变量注入管理员，还是首启向导）
- Docker 镜像的多架构构建（amd64 / arm64）

（Observation 保留期已定为 14 天，见 5.2 与 Task 12。）

### 11.1 计划 01 结束时带入计划 02 的条目

以下由最终整分支评审发现，经裁决记录而非在收尾处修复。按重要性排序。
**六项已全部在计划 02 的 Task 1 中修复（commit e8cacb6），保留在此作为记录。**

1. ~~**`managed_apps#index` 未加 guard 调用 `cached_app_hosts`** —— 一份无法解析的 `deploy.yml` 会让整个 `/apps` 页返回 500，而不只是影响那一个应用。这是计划 02 的首个条目。~~（已修复）

2. ~~**`last_poll_error_at` 每轮失败都被覆写**，而界面横幅声称「自 X 起每轮都失败」—— 于是坏了几天的应用永远显示「不到一分钟前」，而一次瞬时的 5 秒解析超时会让总览断言「采集已停止」。应记录**首次失败**的时间戳。~~（已修复）

3. ~~**两处文案把「我没看清」说成「机器没了」**：纯粹的陈旧会被标为「机器失联」（相邻的「已过期」可消歧）；容器行不可解析时，一台**实际可达**的主机也被渲染为「失联」。改文案需与 `level` 的状态模型（见 10.3）一起想清楚。~~（已修复）

4. ~~**合并 stderr 的副作用**：happy path 上任何一行 stderr 都会把该主机整份路由载荷降级为 `unrecognized_row`。低频，且 `raw` 列可兜底。~~（已修复）

5. ~~**陈旧阈值应由实际节奏推导**而非硬编码 3 分钟，见 10.4 —— 或让 `capture_many` 并发化以压低单轮耗时。~~（已修复）

另有一项纯整洁性条目：~~`latest_for` 形态的查询在代码库中有三份副本，行为一致但会分叉。~~（已收敛到 `LatestPerHost` concern）

---

## 12. 决策记录

| 决策 | 结论 | 依据 |
|---|---|---|
| 项目定位 | 认真运营的开源项目 | 用户明确选择 |
| 是否接管构建 | 否，只做控制面 | 2.3 的能力分界；不碰源码则安全面大幅缩小 |
| 技术栈 | Rails + 直接引 kamal gem | 见第 10 节 |
| 权限模型 | 多用户 + viewer/operator + 审计日志 | 「可以拿去公司用」的分水岭 |
| 状态获取 | agentless SSH + 可选 hook，否决 agent | 3.1 |
| deploy.yml 来源 | 手动粘贴，v1 不接 git | 用户明确选择；使面板零 git 凭据 |
| 强制解锁 | v1 提供，带三重约束 | 用户明确选择；7.4 |
| deploy.yml 解析 | 受限子进程中执行，且新建 Application 仅限 operator | 7.6：Kamal 对 deploy.yml 做 ERB 求值 + YAML.unsafe_load，粘贴即代码执行 |
| 支持的 Kamal 版本 | **仅 Kamal 2+，不支持 1.x** | 用户明确决定；1.x 的 Traefik / 锁 / 标签模型不同，兼容等于两套代码路径 |
| 验证基线 | kamal v2.12.0 + kamal-proxy v0.10.0 | 第 4 节 12 条事实已在此版本逐条复核 |
| UI 视觉方向 | 37signals 设计语言（主要参考 Basecamp） | 用户明确选择；且 Kamal 本身即 Basecamp 产物，气质一致 |
| destination 覆盖文件 | 接入时额外接受一份可选的 `deploy.<destination>.yml` | Task 3 实施时发现：Kamal 会 deep-merge 该文件，缺了它则 staging/production 的主机覆盖丢失，面板轮询错误机器 |
| `ssh.proxy_command` | 一律拒绝，永久性产品决策 | Task 6 实施时核实：net-ssh 的 Proxy::Command 用 IO.popen 执行该字符串，等于让配置文件在面板宿主机上跑任意命令 |
| `ssh.proxy` | 仅支持单跳，含逗号即拒绝 | 同上：Proxy::Jump 继承 Proxy::Command，其 extra_jumps 段未经解析直接进 shell 命令行 |
| `servers:` 主机与 `ssh.port` | 一并按保守字符集校验，端口强制整数 | 代理生效后，命令行模板的 %h/%p 由二者代入，同样抵达 IO.popen —— 只校验 proxy 关不掉这个面 |
| 写操作的执行方式 | 子进程调用 kamal CLI，而非自己用 Commands::App 拼命令 | 语义等价：rollback 会触发用户的 hook、切换 proxy 路由、跑健康检查。自己重实现等于再造一个必须与 Kamal 永远一致的实现 |
| CLI 的私钥注入 | 每次调用独立 ssh-agent，密钥经 stdin 注入 | 私钥全程不落盘；2026-09-06 对真实主机实测通过 |
| 项目名 | kamal-panel | 用户明确选择 |
